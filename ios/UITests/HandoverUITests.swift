/**
 * **The handover, from the phone that answers it.**
 *
 * An agent on a real server hits a login wall, calls `browser.handover` with a
 * sentence, and stops. On this phone, inside the session, the page is curtained
 * and the person holding it is offered the way in — they take it, type into the
 * **real page**, hand it back, and the agent carries on.
 *
 * Everything on the other end of this is real and none of it is in this process:
 * `out/headless/host.mjs` with a real Chromium in it, a real login page served
 * over loopback, a real MCP client holding the token the host minted for *this
 * session's* launch, and a second real device on the wire. `ios/Harness/
 * live-handover.ts` is that side; `ios/Harness/live-handover.sh` starts both and
 * is the only supported way to run this.
 *
 * ## Why it takes turns through files
 *
 * The two ends cannot call each other. So they leave notes in `TD_PROOF`: this
 * writes `steps/<name>` when it has reached a stage, the Mac writes
 * `cues/<name>` when it has done its part. A simulator process is a plain macOS
 * process, so both read and write the same paths. Every wait below is bounded
 * and names what did not happen.
 *
 * ## What this asserts, and what it deliberately leaves to the Mac
 *
 * On screen: the curtain carrying the agent's own sentence, the offer, the
 * sentence a **second** device gets instead of a button, the page live under
 * this device's hands, and the two ways back. Those are this phone's to prove
 * and it photographs every one of them.
 *
 * Not here: that the characters reached the page, that the agent was refused
 * while the person held it, and that the blocked call resolved. A phone reading
 * its own screen and agreeing with itself is one program's opinion — so the
 * keystrokes are read by the **web server that served the page**, and the
 * refusals by the agent itself, both in `<proof>/evidence.jsonl`.
 *
 * ## `TEST_RUNNER_TD_*` goes in front of `xcodebuild`
 *
 * In its environment, never after it as build settings. Measured on Xcode 26.6:
 * the argument form is parsed as a build setting, never reaches the runner, and
 * every case here skips while the run reports `** TEST SUCCEEDED **`. The script
 * does it correctly; do not run this by hand any other way.
 */

import XCTest

final class HandoverUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Where the two ends leave notes for each other. Absent means "not this run".
    private var proof: String { ProcessInfo.processInfo.environment["TD_PROOF"] ?? "" }
    /// Where the six digits will appear, once this phone says it is standing at the field.
    private var codeFile: String { ProcessInfo.processInfo.environment["TD_CODE_FILE"] ?? "" }
    /// The string this phone types into the page. Minted per run by the Mac.
    private var marker: String { ProcessInfo.processInfo.environment["TD_MARKER"] ?? "" }
    private var shots: String? { ProcessInfo.processInfo.environment["TD_SHOTS"] }

    private static let notRunning =
        "The handover proof is not being driven. Run ios/Harness/live-handover.sh, which starts a "
        + "headless host with a real browser, pairs this simulator to it and sets TD_PROOF."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(proof.isEmpty || marker.isEmpty, Self.notRunning)
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - The whole chain

    func testAnAgentAsksForAPersonAndThePhoneAnswers() throws {
        try pair()
        try waitForCue("paired")
        try waitForConnected(timeout: 240)
        shoot("03-connected")

        // A session this phone starts, in the folder the host granted it.
        try startSession()
        shoot("04-session")
        say("session-open")

        /* -- the page the agent opened comes to the session ----------------- */

        try waitForCue("page-open", timeout: 180)
        let title = element("session.page.title")
        XCTAssertTrue(title.waitForExistence(timeout: 120),
                      "the window the agent opened should appear over this session's terminal")
        let stage = element("session.page.stage")
        XCTAssertTrue(stage.waitForExistence(timeout: 60),
                      "the machine is casting that window, so there should be a canvas")
        shoot("05-the-page-in-the-session")
        say("page-visible")

        /* -- the curtain, and the agent's own sentence ---------------------- */

        try waitForCue("asking", timeout: 180)
        let bar = element("session.page.handover")
        XCTAssertTrue(bar.waitForExistence(timeout: 120),
                      "browser.handover should reach this phone as a question it can answer")
        XCTAssertTrue(waitForWords("The agent needs you on this page", timeout: 60),
                      "the bar should say what it is about; the screen said \(whatTheBarSays())")
        XCTAssertTrue(waitForWords("billed to", timeout: 20),
                      "the sentence should be the agent's own; the screen said \(whatTheBarSays())")
        XCTAssertTrue(app.buttons["session.page.handover.take"].waitForExistence(timeout: 20),
                      "nobody has answered yet, so this device should be offered the way in")
        shoot("06-the-curtain-and-the-question")
        say("saw-asking")

        /* -- somebody else answers it first --------------------------------- */

        try waitForCue("taken-elsewhere", timeout: 180)
        XCTAssertTrue(waitForWords("Another device is answering this", timeout: 90),
                      "a second watcher took it, so this one should be told so; the screen said \(whatTheBarSays())")
        /*
         * The security claim, on this screen.
         *
         * Not a disabled button and not a demoted one: the only thing this
         * device could do from here is reach into a page somebody else is typing
         * a password into, so there is nothing to press at all.
         */
        XCTAssertFalse(app.buttons["session.page.handover.take"].exists,
                       "a device that does not hold the page must not be offered a way to take it")
        XCTAssertFalse(app.buttons["session.page.handover.carryon"].exists,
                       "and must not be offered a way to hand back somebody else's page")
        shoot("07-another-device-has-it")
        say("saw-elsewhere")

        /* -- and lets go, so this phone can have it ------------------------- */

        try waitForCue("released", timeout: 120)
        let take = app.buttons["session.page.handover.take"]
        XCTAssertTrue(take.waitForExistence(timeout: 60),
                      "the other device let go, so the question is this one's to answer again")
        shoot("08-offered-again")

        /* -- this phone becomes the person the handover was waiting for ----- */

        take.tap()
        XCTAssertTrue(waitForWords("You have this page", timeout: 60),
                      "the take should be granted and said so; the screen said \(whatTheBarSays())")
        let carryOn = app.buttons["session.page.handover.carryon"]
        XCTAssertTrue(carryOn.waitForExistence(timeout: 20),
                      "a device holding the page is offered the two ways out and nothing else")
        XCTAssertTrue(app.buttons["session.page.handover.stop"].exists)
        XCTAssertFalse(app.buttons["session.page.handover.take"].exists)
        shoot("09-i-have-the-page")
        say("mine")

        // While this is true the agent is shut out. That is read on the Mac, from
        // the agent's own refusals; this only waits for it to have been tried, so
        // the attempt happens inside the window where this device holds the page.
        try waitForCue("agent-refused", timeout: 120)
        shoot("10-the-agent-is-shut-out")

        /* -- typed into the real page --------------------------------------- */

        /*
         * **One tap, which is the whole of it now.**
         *
         * The rule used to be the field *and then* a keyboard button in the app's
         * own chrome — `session.page.keyboard`, pressed here — on the argument
         * that nothing on the frame wire carries focus, so this app could not
         * raise a keyboard onto a field it had not been told about.
         *
         * > *"This keyboard should not be working like this. If we just click
         * > inside and type from our keyboard, it should work… I should not have
         * > to have this separate button of keyboard. It should just come up from
         * > down, and the original native button should be there to move it down
         * > if I want, not a separate keyboard here inside the browser window."*
         *
         * So the button is deleted and `WatchView.onTap` takes first responder in
         * the same gesture that sends the click: the keyboard comes up with the
         * tap that focused the field, and the way back down rides on the keyboard
         * itself (`browser.page.keys.dismiss`, the same
         * `keyboard.chevron.compact.down` the terminal's bar has always had).
         *
         * The tap lands at the middle of the canvas, which is the middle of the
         * page's own viewport, and the login page puts the account field exactly
         * there for that reason.
         */
        /*
         * A beat first, and it is not a hedge.
         *
         * The curtain stops the pixels at the source, so taking the page
         * *restarts* the screencast — and every gesture on the canvas is refused
         * by this app until an unmasked frame has arrived (`WatchView` guards
         * each one on `lastFrame.masked`). Tapping in the same breath as the
         * take would be tapping at a lock card.
         */
        sleep(4)
        stage.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 20),
                      "a tap on a page this device holds should raise the keyboard on the canvas — "
                      + "there is no keyboard button to press any more")
        // The system's QuickPath tutorial, put up the first time a keyboard
        // appears on a fresh simulator. Nothing to do with this app.
        let quickPath = app.buttons["Continue"]
        if quickPath.exists { quickPath.tap() }
        app.typeText(marker)
        sleep(2)
        shoot("11-typed-into-the-page")
        say("typed")

        // And the page itself says it arrived. Read by the web server, not here.
        try waitForCue("page-received", timeout: 120)
        let received = (try? String(contentsOfFile: "\(proof)/cues/page-received", encoding: .utf8)) ?? ""
        XCTAssertTrue(received.contains("\"matched\":true"),
                      "the page the person typed into should have received the characters, and said: \(received)")

        /* -- handed back, and the agent carries on -------------------------- */

        carryOn.tap()
        say("handed-back")
        XCTAssertTrue(waitForGone(bar, timeout: 90),
                      "handing back ends the question, so the bar should go")
        /*
         * **And the keyboard goes with it.**
         *
         * The page stops being this device's the moment the baton returns, and
         * the host curtains it again in the same breath — every keystroke after
         * that is refused at the source. A keyboard still standing over it is
         * half a phone screen offering to type into something that cannot take
         * it, which is what the first harness run photographed in `12-…`.
         *
         * Asserted here rather than in a unit test because the state that
         * outlived its grant is the *system keyboard*, and nothing below
         * XCUITest can see whether that is on screen. What a unit test can pin —
         * that handing back counts as losing the page even though the handover
         * goes to nil rather than to `mine: false`, which is the shape the first
         * fix got wrong — is `SessionPageTests.testHandingBackCountsAsLosing…`.
         */
        XCTAssertTrue(waitForGone(app.keyboards.firstMatch, timeout: 30),
                      "a keyboard over a page that is no longer this device's is an offer that does nothing")
        shoot("12-handed-back")

        try waitForCue("carried-on", timeout: 180)
        sleep(3)
        shoot("13-the-agent-carried-on")
        say("done")
    }

    // MARK: - Steps

    private func pair() throws {
        guard app.reachPairingField(timeout: 20) else {
            // Already paired from a previous run — a pairing lasts until it is
            // revoked. The script erases the simulator, so this is the rare path.
            shoot("01-already-paired")
            say("at-the-pairing-screen")
            return
        }
        shoot("01-at-the-pairing-field")
        say("at-the-pairing-screen")
        let code = try waitForCode()
        let field = app.textFields["pairing.field"]
        field.tap()
        field.typeText(code)
        // Six digits submit themselves; the button is for a paste the field
        // refused. Tapped only if it is still there.
        let submit = app.buttons["pairing.submit"]
        if submit.exists && submit.isHittable { submit.tap() }
        shoot("02-code-typed")
    }

    private func waitForCode() throws -> String {
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: codeFile, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        shoot("zz-no-code")
        throw XCTSkip("nothing wrote six digits to \(codeFile). \(Self.notRunning)")
    }

    private func startSession() throws {
        let new = app.buttons["sessions.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 90),
                      "the host advertises `create` and granted a folder, so the button should be there")
        new.tap()
        // A menu when there are folders to choose from, a plain button when there
        // are none. Both are real states of a real host.
        let fromMenu = app.buttons["sessions.newDefault"]
        if fromMenu.waitForExistence(timeout: 4) {
            fromMenu.tap()
        } else {
            let plain = app.buttons["New session"].firstMatch
            if plain.waitForExistence(timeout: 4) { plain.tap() }
        }
        XCTAssertTrue(app.buttons["terminal.actions"].waitForExistence(timeout: 60),
                      "starting a session should open it")
    }

    // MARK: - Turn-taking

    /// Tell the Mac this phone has reached a stage.
    private func say(_ name: String) {
        let dir = "\(proof)/steps"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(ISO8601DateFormatter().string(from: Date()))\n".write(
            toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
    }

    /// Wait for the Mac to say it has done its part.
    private func waitForCue(_ name: String, timeout: TimeInterval = 240) throws {
        let at = "\(proof)/cues/\(name)"
        let failed = "\(proof)/cues/failed"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: at) { return }
            if FileManager.default.fileExists(atPath: failed) {
                let why = (try? String(contentsOfFile: failed, encoding: .utf8)) ?? ""
                shoot("zz-mac-side-failed")
                XCTFail("the Mac side stopped before “\(name)”: \(why)")
                return
            }
            usleep(400_000)
        }
        shoot("zz-no-cue-\(name)")
        XCTFail("the Mac never reached “\(name)” in \(Int(timeout))s")
    }

    // MARK: - Helpers

    /// Identifiers on containers and modifiers land on elements XCUITest does not
    /// classify as buttons or text, so every one of them is asked for by
    /// descendant rather than by type. `SessionPageUITests` does the same.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /**
     * Words on the screen, by what they say rather than by an identifier.
     *
     * The bar's headline is a `Text` inside an `HStack` that carries an icon and
     * a `Spacer`, and SwiftUI merges that row into **one** accessibility element
     * — so `session.page.handover.state` never reaches the tree and a query on it
     * waits forever beside a screen that plainly says the words. Measured here on
     * 2026-08-25 against the screen photographed in `06-…`.
     *
     * The three sentences this asks for are `SessionHandover.headline`'s own and
     * are pinned in `SessionPageTests`, so reading them off the screen is reading
     * the decision rather than a layout.
     */
    private func waitForWords(_ words: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", words)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.descendants(matching: .any).matching(predicate).firstMatch.exists { return true }
            usleep(300_000)
        }
        return false
    }

    /// Everything the handover bar is currently saying, for a failure sentence
    /// that names the screen instead of an identifier.
    private func whatTheBarSays() -> String {
        let bar = element("session.page.handover")
        guard bar.exists else { return "(no handover bar on screen)" }
        let texts = bar.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        return texts.isEmpty ? "(a bar with no text in it)" : texts.joined(separator: " | ")
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(300_000)
        }
        return false
    }

    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = element("connection.pill")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            if app.buttons["sessions.new"].exists { return }
            usleep(400_000)
        }
        shoot("zz-not-connected")
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    private func shoot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let shots else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
