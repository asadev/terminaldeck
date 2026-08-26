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
 * ## There is no ceremony left in the walk, and that is the point of it
 *
 * A device used to arrive unconnected: `COPILOT-REMOTE.md` §6 made the copilot a
 * **separate connection** with its own six-digit code, so this walk minted one
 * through the control server and typed it into the phone before expecting a
 * screen. Asad deleted that on 2026-08-19 — *"if we are connecting as my device
 * copilot automatically comes, if we connect as guest then copilot don't
 * come"* — so the walk now pairs, and the copilot is simply there.
 *
 * Which makes the *absence* of the old screens an assertion in its own right,
 * and every case below carries one: no code field, no Settings row, no
 * "connect" anywhere. A build that helpfully put one back would be asking for a
 * code nothing on that machine can mint.
 *
 * ## Running it
 *
 *     ios/Harness/run.sh host --port 8787 --copilot mine --folders /tmp/tdwork &
 *     TEST_RUNNER_TD_CONTROL=127.0.0.1:8788 \
 *     TEST_RUNNER_TD_COPILOT=mine \
 *     TEST_RUNNER_TD_SHOTS=/tmp/td/copilot-shots \
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/CopilotScreensUITests
 *
 * `TD_COPILOT` says what the stand-in was started with, so the walk asserts what
 * that host should produce rather than photographing whatever appears. The
 * stand-in has **two** states since 2026-08-19 and this suite has one case for
 * each of the three names that reach them:
 *
 *  - **`absent`** — a host with no copilot layer, which still advertises the
 *    capability because the stand-in sends `CAPABILITIES` verbatim. Nothing
 *    about a copilot may appear.
 *  - **`guest`** — the same host, telling this phone it is not one of his. Also
 *    no key and no capability, which is `server.ts`'s choice rather than the
 *    harness being lazy, so from this end it is indistinguishable from `absent`
 *    — and having a case for each is what pins that they *stay*
 *    indistinguishable.
 *  - **`mine`** — one of his own devices, holding every tier. `--copilot alter`
 *    still reaches it; the stand-in accepts the old level names so that an
 *    existing script reports a client problem rather than a harness one.
 *
 * There is no `none` case any more. It meant *connected with every box
 * unticked*, which was a per-device narrowing that no longer exists — "My
 * device" means full access — and the stand-in cannot produce it. `CopilotView`
 * still draws `notGranted` for a far end that sends an empty grant anyway, and
 * `CopilotLinkTests` is where that is pinned, because it needs a host this
 * harness deliberately will not be.
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

    /// The `--copilot` values that mean *one of his own devices*. `mine` is the
    /// name; the rest are the pre-2026-08-19 tier levels, which the stand-in
    /// still accepts and folds into `mine` so that an older script reports a
    /// client problem rather than an unknown-flag one.
    private static let mine: Set<String> = ["mine", "read", "act", "alter", "none"]

    private static let notRunning =
        "No stand-in. Start ios/Harness/run.sh host --copilot <absent|guest|mine> and pass "
        + "TEST_RUNNER_TD_CONTROL and TEST_RUNNER_TD_COPILOT — see this file's header."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(control.isEmpty || grant.isEmpty, Self.notRunning)
        app = XCUIApplication()
        app.launch()
        // Pairings live in the Keychain and outlive the process, so a run that
        // did not clear them would start already paired to whatever the last one
        // left behind — a different host, offering this phone a different answer
        // about the copilot.
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
     * is ahead of what it can serve. Nothing about a copilot may appear: no
     * pill, and above all nothing offering to connect one, because that build
     * has nothing to connect.
     */
    func testAMachineThatOnlyAdvertisesACopilotShowsNone() throws {
        try XCTSkipUnless(grant == "absent", "this case is for --copilot absent")

        // **No fourth pill**, which is the whole answer here. *"If the copilot
        // is not connecting, this icon should not be inside the pill — then it
        // will be three icon pill."* A machine whose build has no copilot in it
        // can never have one, so the pill is never drawn for it and there is
        // nothing behind it to be wrong about.
        XCTAssertFalse(app.openCopilotTab(),
                       "a machine that only advertises a copilot gets no pill")
        capture("absent-01-three-pills")

        try nothingOffersToConnectACopilot()
        capture("absent-02-settings-has-nothing-to-connect")
    }

    /**
     * **A phone paired as a guest gets a copilot-shaped nothing.**
     *
     * *"If we connect as guest then copilot don't come."* This is the assertion
     * that sentence buys, and it is the one worth having: a fourth pill on a
     * guest's phone is a door to somebody else's agent, and the approval screen
     * promises in his own words that it is never there — *"Guest — You choose
     * what they can reach. The copilot is never shared."*
     *
     * It is indistinguishable from the case above, deliberately, and that is
     * `server.ts`'s decision rather than a gap here: `capabilitiesFor` strips
     * the name from what a guest is told rather than merely refusing the verbs,
     * because *"a client that is told the capability exists draws the tab, and a
     * tab that refuses on every press is a worse answer than a client that never
     * knew."*
     */
    func testAGuestGetsNoCopilotAtAll() throws {
        try XCTSkipUnless(grant == "guest", "this case is for --copilot guest")

        XCTAssertFalse(app.openCopilotTab(), "the copilot is never shared")
        capture("guest-01-three-pills")

        try nothingOffersToConnectACopilot()
        capture("guest-02-nothing-to-connect")
    }

    /**
     * **A phone paired as his own device arrives with the copilot already
     * there.**
     *
     * The case that replaced `testADeviceWithNoConnectionIsOfferedACode`, and it
     * asserts the opposite of what that one did. There is no state where a
     * device is paired and the copilot is "not connected yet": *"instead of
     * giving mobile app separate connection for copilot just make it like if we
     * are connecting as my device copilot automatically comes."*
     *
     * Nothing was pressed between pairing and this screen. That is the whole
     * assertion, and the code field being absent is the other half of it.
     */
    func testHisOwnDeviceArrivesWithTheCopilotAlreadyThere() throws {
        try XCTSkipUnless(Self.mine.contains(grant),
                          "this case needs a host with a copilot for this phone")

        XCTAssertTrue(app.openCopilotTab(),
                      "four pills, with nothing typed and nothing pressed")
        capture("connect-01-four-pills-with-nothing-pressed")

        try nothingOffersToConnectACopilot()
        capture("connect-02-nothing-to-connect")
    }

    /**
     * A phone with all three tiers: the whole walk.
     *
     * Open the copilot — which takes one tap on a pill that is simply there —
     * watch, start a run, ask it something, read the answer and the tool row it
     * caused, answer the confirmation it raises with every argument in front of
     * you, and see where the answer landed. Then the other kind of question: one
     * raised at the desk, which this phone may watch and must not be able to
     * answer.
     */
    func testTheWholeCopilotWalk() throws {
        try XCTSkipUnless(Self.mine.contains(grant), "this case is for --copilot mine")

        XCTAssertTrue(app.openCopilotTab(),
                      "his own device arrives with the copilot already there")

        /*
         * **The pill arrived with the device, and the chat box has the bottom of
         * the phone to itself.**
         *
         * Two of the review's changes, asserted together because they are one
         * screen: *"if the copilot is connected, then four icon pill,
         * automatically"* — which is now decided by the device's kind and
         * nothing else — and *"pill should not be inside the chat box — there
         * should be a back button to go back on home."*
         *
         * The bar being **absent while standing on the copilot** is the part a
         * screenshot alone would not settle, because on iOS 26 the bar is a
         * floating pill and "over the composer" and "below it" look similar at a
         * glance in a thumbnail. And `copilot.back` existing is what makes
         * hiding it safe at all — this screen is a tab root, so without that
         * button there is no chevron, no gesture and no way out.
         */
        XCTAssertTrue(app.buttons["copilot.back"].waitForExistence(timeout: 10),
                      "the copilot's only way home")
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "either we will type or we will use the pill")

        // And it goes home. Then back in through the pill, which is the fourth
        // one because this is one of his own machines.
        app.buttons["copilot.back"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.buttons["Copilot"].waitForExistence(timeout: 10),
                      "four pills on a machine whose copilot is this phone's")
        capture("alter-01b-four-pills")
        XCTAssertTrue(app.openCopilotTab(), "and the fourth one goes back in")

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

        /*
         * Both lists are behind the gear now rather than behind a `…`.
         *
         * The overflow menu that used to be in this slot carried a strict subset
         * of `CopilotControlView` — the two lists, Interrupt and Stop — and a gear
         * beside a `…` offering less than the gear is two doors to one room with the
         * smaller one first. So the menu is gone and this walk goes through the
         * control screen, which is one push rather than a menu and therefore has
         * a back chevron rather than a Done.
         */
        app.buttons["copilot.controls"].tap()
        XCTAssertTrue(app.buttons["copilot.controls.sessions"].waitForExistence(timeout: 10))

        // What it started.
        app.buttons["copilot.controls.sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions it started"].waitForExistence(timeout: 10))
        capture("alter-09-sessions-it-started")
        app.buttons["Done"].tap()

        // Everything it did, including the refusal.
        app.buttons["copilot.controls.activity"].tap()
        XCTAssertTrue(app.navigationBars["Everything it did"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'not-granted'"))
            .firstMatch.waitForExistence(timeout: 10),
                      "a refused call is the row this screen exists for")
        capture("alter-10-everything-it-did")
        app.buttons["Done"].tap()
        // Back out of the controls, to the conversation this walk started on.
        app.navigationBars.buttons.element(boundBy: 0).tap()
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

    /**
     * **Nothing anywhere offers to connect a copilot**, asserted in every case
     * above rather than once.
     *
     * This replaces `connectTheCopilot()`, which minted a six-digit code through
     * the control server and typed it into a field in Settings. Both the code
     * and the field are deleted: *"instead of giving mobile app separate
     * connection for copilot just make it like if we are connecting as my device
     * copilot automatically comes."*
     *
     * A deletion is worth walking rather than assuming, because the failure it
     * guards against is somebody putting the row back to be helpful — and a
     * connect screen in a build with no connect verb is a form that can only
     * fail, on every host, for a reason nothing on either end can explain.
     */
    private func nothingOffersToConnectACopilot() throws {
        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable")
        XCTAssertFalse(app.buttons["settings.copilot"].waitForExistence(timeout: 5),
                       "there is nothing left in Settings to connect")
        XCTAssertFalse(app.textFields["copilot.connect.field"].exists,
                       "there is no copilot code, anywhere, on any screen")
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

    /**
     * **Its files and its routines, on the phone.**
     *
     * > *"the copilot has things in the macbook side and the windows side… its
     * > memory folder, the folder's own instruction, what it was handed, its
     * > instructions… 'check the work before it counts as done', 'what happened
     * > overnight', all of these are like separate settings for co-pilot."*
     *
     * The two cards the Mac's Copilot pane has always had, drawn off the two
     * wires the stand-in now serves. This walks into each: a file row into its
     * editor, a routine's `…` into its menu and its read-only viewer. The
     * photographs are the point — the panels were built without a rendered look,
     * and this is the look.
     */
    func testTheFilesAndRoutinesPanels() throws {
        try XCTSkipUnless(Self.mine.contains(grant), "this case is for --copilot mine")

        XCTAssertTrue(app.openCopilotTab(), "his own device arrives with the copilot already there")
        XCTAssertTrue(app.buttons["copilot.controls"].waitForExistence(timeout: 10))
        app.buttons["copilot.controls"].tap()

        let yours = app.buttons["copilot.files.yours"]
        XCTAssertTrue(yours.waitForExistence(timeout: 20), "the files card should list its instructions")
        // Scroll it into view: the card sits below the session and permission
        // panels, which is where he put it — after what the copilot is, before
        // what it may reach.
        app.swipeUp()
        capture("files-01-card")

        yours.tap()
        XCTAssertTrue(app.textViews["copilot.file.editor"].waitForExistence(timeout: 10),
                      "its instructions open in an editor")
        capture("files-02-editor-yours")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let contract = app.buttons["copilot.files.contract"]
        XCTAssertTrue(contract.waitForExistence(timeout: 10))
        contract.tap()
        XCTAssertTrue(app.staticTexts["copilot.file.readonly"].waitForExistence(timeout: 10),
                      "the app's half of the prompt says why it cannot be changed")
        capture("files-03-contract-readonly")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let more = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'copilot.routine.more.'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the routines card should list the stand-in's six")
        app.swipeUp()
        capture("routines-01-card")
        more.tap()
        XCTAssertTrue(app.buttons["Read"].waitForExistence(timeout: 10), "the menu offers Read")
        capture("routines-02-menu")
        app.buttons["Read"].tap()
        XCTAssertTrue(app.staticTexts["copilot.routine.file.readonly"].waitForExistence(timeout: 10)
                      || app.otherElements["copilot.routine.file.readonly"].waitForExistence(timeout: 2),
                      "the viewer says why the file is read-only here")
        capture("routines-03-read")
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
