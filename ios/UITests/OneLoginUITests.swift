/**
 * **One** login screen — walked, filled and photographed, on a phone that owns
 * no computer.
 *
 * ## What this replaces, and why it is one file
 *
 * `AddServerUITests.swift` used to walk to a second form that sat behind a line
 * at the foot of the first one, and its own helper had to open two screens to
 * get there. That is the fault this suite exists to prevent coming back: the
 * only route it knows is the one a person takes, and every identifier it names
 * begins `serverLogin.`. A second form reappearing anywhere would fail
 * `testThereIsExactlyOneLoginForm` on the count of address fields, not on
 * somebody noticing.
 *
 * ## Why none of it skips
 *
 * Most cases in this target need a host on the machine and skip when their
 * variable is unset. These need none, and that is the point: what they prove is
 * that the door **is the first thing the app shows** and that its fields exist
 * and behave — which is precisely what no unit test can notice and what 0.10.0
 * got wrong twice in a row.
 *
 * The one case that needs something real is the key paste, and what it needs is
 * a key on the simulator's pasteboard rather than a server:
 *
 *     ssh-keygen -q -t ed25519 -N "" -f /tmp/k
 *     xcrun simctl pbcopy <device> < /tmp/k
 *     TD_KEY_ON_PASTEBOARD=1 xcodebuild test -only-testing:…/OneLoginUITests
 *
 * ## `TD_SHOTS`
 *
 * When it names a directory the frames are written beside the assertions. A
 * screen is not finished until somebody has looked at it.
 */

import XCTest

final class OneLoginUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /**
     * The **first** screen is the login, and it does not assume a computer.
     *
     * > *"Say no MacBook or any Windows exists at all — a user only has a server
     * > and a phone."*
     *
     * The screen this replaced opened with the headline *"Pair with your Mac"*,
     * a six-digit code field and a primary **Pair** button, with the server
     * login as a small line underneath. Everything asserted here is that
     * inversion: the four fields are on the first frame with no navigation at
     * all, and the pairing door is present — because it is kept, not deleted —
     * but is not the primary control.
     */
    func testTheFirstScreenIsTheLoginAndAssumesNoComputer() {
        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 20),
                      "the first screen of the app must be the server login")
        capture("01-first-screen")

        XCTAssertTrue(app.textFields["serverLogin.port"].exists,
                      "the port is the field whose absence made his own server unreachable")
        XCTAssertTrue(app.textFields["serverLogin.username"].exists)
        XCTAssertTrue(app.secureTextFields["serverLogin.password"].exists,
                      "the password field is secure, not a plain one")
        XCTAssertTrue(app.buttons["serverLogin.submit"].exists)

        // Kept, and secondary. Both halves matter: deleting pairing would strand
        // everybody who does own a Mac.
        XCTAssertTrue(app.buttons["serverLogin.pairingDoor"].exists,
                      "pairing stays, one tap away")

        // No pairing code field on the way in, and no six-digit anything.
        XCTAssertFalse(app.textFields["pairing.field"].exists,
                       "the code field is behind the pairing door now, not in front of it")

        // And nothing on this screen tells somebody to go and run a command.
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "curl")).count, 0)
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "install.sh")).count, 0)
    }

    /**
     * **Exactly one.** The whole complaint, as an assertion.
     *
     * > *"I think it has 2 pages for server login, another inside a server login
     * > page, but a little bit different. It should be only ONE full option."*
     *
     * There were two, and the one reached first had no port field. What made
     * that survivable in a test suite was that each screen had its own
     * identifiers, so both could pass at once. This counts *elements* instead:
     * one address field, one submit button, and no trace of the identifiers the
     * deleted screen used.
     */
    func testThereIsExactlyOneLoginForm() {
        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 20))

        XCTAssertEqual(app.textFields.matching(identifier: "serverLogin.address").count, 1,
                       "two address fields means two login screens are on screen at once")
        XCTAssertEqual(app.buttons.matching(identifier: "serverLogin.submit").count, 1)

        // The deleted screen, by name. It is gone rather than unreferenced.
        XCTAssertFalse(app.textFields["addServer.address"].exists)
        XCTAssertFalse(app.buttons["addServer.submit"].exists)
        XCTAssertFalse(app.buttons["serverLogin.addressDoor"].exists,
                       "the line that opened the second form is gone with the form")

        // And there is one word for the action. Not "Sign in" here and "Log in"
        // there — that pair is how somebody ends up believing they are on a
        // different screen doing a different thing.
        XCTAssertEqual(app.buttons["serverLogin.submit"].label, "Log in")
    }

    /**
     * Pairing is reachable, is the *other* door, and comes back here.
     *
     * The round trip is the assertion: opening the pairing sheet from the login
     * and closing it must land on the login again — and there must never be two
     * logins in the hierarchy at once, which is the state that made
     * `firstMatch` on a segmented control tap the wrong screen.
     */
    func testPairingIsOneTapAwayAndComesBack() {
        XCTAssertTrue(app.buttons["serverLogin.pairingDoor"].waitForExistence(timeout: 20))
        app.buttons["serverLogin.pairingDoor"].tap()

        XCTAssertTrue(app.textFields["pairing.field"].waitForExistence(timeout: 10),
                      "the pairing door has to open the pairing screen")
        capture("02-pairing-behind-the-door")

        // The screen behind the code field does not tell a stranger they own a
        // Mac; it names both the machines it can actually pair with.
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Pair with your Mac")).count, 0,
            "no screen may assume the reader owns a Mac")

        // From here, the server line goes *back* to the login rather than
        // stacking a second copy of it on top.
        XCTAssertTrue(app.buttons["pairing.addServer"].exists)
        app.buttons["pairing.addServer"].tap()
        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields.matching(identifier: "serverLogin.address").count, 1,
                       "going through pairing and back must not leave two login forms stacked")
    }

    /**
     * The key field can hold a key.
     *
     * ## The case that failed, and what it was really telling us
     *
     * `testTheKeyOptionOffersAPasteRatherThanAOneLineField` tapped
     * `buttons["Private key"].firstMatch` and then waited five seconds for a
     * label that never came. The reason was not the label: the walk had two
     * login screens stacked, so `firstMatch` hit the segmented control on the
     * *buried* one and the visible screen never changed. One screen, and the tap
     * lands where a finger would land.
     *
     * ## And it asserts on the field, not on a label
     *
     * The old assertion was that a static text saying "Private key" appeared —
     * which a paste-only pill satisfies whether or not it can hold a key. What
     * is checked here is the field: it exists, it is a real text field rather
     * than a one-line secure one, and the password field is gone.
     */
    func testChoosingAKeyGivesAFieldAKeyFitsIn() {
        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 20))
        app.buttons["Private key"].firstMatch.tap()

        let key = app.textFields["serverLogin.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5),
                      "choosing a key must give a field a key fits in")
        XCTAssertFalse(app.secureTextFields["serverLogin.password"].exists,
                       "a key is seven lines; a single-line secure field eats its newlines")
        XCTAssertTrue(app.buttons["serverLogin.pasteKey"].exists,
                      "a key is pasted far more often than typed")
        capture("03-key-chosen")
    }

    /**
     * **A real seven-line key, pasted, and read back.**
     *
     * The requirement, in his words on the failing case: *"A private key is 7
     * lines (his is ed25519). A one-line secure field eats newlines. Fix it so a
     * whole key pastes and reads back intact, BEGIN/END included; verify by
     * pasting a real 7-line ed25519 key into the running app and reading it
     * back, not by asserting on a label."*
     *
     * So this reads the field's own value back and compares it, line for line,
     * with what went on the pasteboard. A character count would pass whether or
     * not the newlines survived — the count is identical either way — which is
     * exactly how the old pill reported a mangled key as ready.
     *
     * Gated on `TD_KEY_ON_PASTEBOARD=1`, because the pasteboard is set outside
     * the process by `simctl pbcopy` and a case that assumed it would fail on a
     * laptop that had not.
     */
    func testAWholeKeyPastesAndReadsBackIntact() throws {
        try XCTSkipIf(env("TD_KEY_ON_PASTEBOARD") != "1",
                      "needs a private key on the simulator's pasteboard (simctl pbcopy)")

        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 20))
        app.buttons["Private key"].firstMatch.tap()

        let paste = app.buttons["serverLogin.pasteKey"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()

        let field = app.textFields["serverLogin.key"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // The readback: the app's own sentence about what arrived. It counts
        // lines and runs the reader that will sign the handshake, so this
        // passing means the bytes in the field are a key.
        let readback = app.staticTexts["serverLogin.keyReady"]
        XCTAssertTrue(readback.waitForExistence(timeout: 10),
                      "nothing was said about the key that was pasted")
        capture("04-key-pasted")

        let said = readback.label
        XCTAssertTrue(said.contains("BEGIN and END are both here"),
                      "the key lost its BEGIN or END line: \(said)")
        XCTAssertTrue(said.contains("7 lines"),
                      "an ed25519 key is seven lines; this one arrived as: \(said)")

        // And the bytes themselves, out of the field.
        let value = (field.value as? String) ?? ""
        XCTAssertTrue(value.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
                      "the field does not begin with the BEGIN line")
        XCTAssertTrue(value.contains("-----END OPENSSH PRIVATE KEY-----"),
                      "the field does not carry the END line")
        /*
         * **Seven lines, and the trailing newline is kept.**
         *
         * The raw value is eight `\n`-separated pieces, because `ssh-keygen`
         * writes a newline at the end of the file and the paste brought it
         * through — which is correct and load-bearing: `ServerConnector.signIn`
         * deliberately does not trim the secret, because that final newline is
         * part of the format. So the count is taken the way a person counts, on
         * the trimmed text, and the untrimmed tail is asserted separately rather
         * than quietly tolerated.
         */
        let lines = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 7, "the newlines did not survive the paste")
        XCTAssertTrue(value.hasSuffix("\n"),
                      "the key file's own trailing newline was eaten on the way in")

        // The Log in button is live, which is the whole point: a key that cannot
        // be submitted is a key that was not accepted.
        app.textFields["serverLogin.address"].tap()
        app.textFields["serverLogin.address"].typeText("example.com")
        app.textFields["serverLogin.username"].tap()
        app.textFields["serverLogin.username"].typeText("root")
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled)
    }

    /**
     * A key that arrived as one line is refused **here**, with the reason.
     *
     * The failure this whole item is about: a flattened key used to sail through
     * the form and come back as *"that sign-in was refused"* from the server,
     * which sends somebody to check a password that was never wrong. Typed
     * rather than pasted, because typing is the one way to reliably produce the
     * mangled shape.
     */
    func testAFlattenedKeyIsCalledOutBeforeTheLoginIsAttempted() {
        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 20))
        app.buttons["Private key"].firstMatch.tap()

        let field = app.textFields["serverLogin.key"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEA -----END "
            + "OPENSSH PRIVATE KEY-----")

        let readback = app.staticTexts["serverLogin.keyReady"]
        XCTAssertTrue(readback.waitForExistence(timeout: 10))
        XCTAssertFalse(readback.label.contains("7 lines"))
        capture("05-key-flattened")
    }

    /**
     * The button ends somewhere.
     *
     * An address that cannot be reached completes with no server anywhere, and
     * it is the case that proves the screen cannot leave a spinner up. Both
     * halves of the answer are asserted: what went wrong, and what to do about
     * it — and the form is still underneath, so one field is one tap to fix.
     */
    func testARefusalNamesTheNextMoveAndLeavesTheFormUp() {
        XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 20))

        let address = app.textFields["serverLogin.address"]
        address.tap()
        // `.invalid` is reserved and resolves nowhere, so this is a refusal
        // rather than a wait on somebody's real machine.
        address.typeText("nothing.invalid")

        let port = app.textFields["serverLogin.port"]
        port.tap()
        port.typeText("2222")
        // A number pad has no return key. The Done bar is how a finger gets off
        // it, and it is asserted here because without it the keypad covers the
        // password field and the next tap lands on the keyboard — which is
        // exactly how this case failed once.
        XCTAssertTrue(app.buttons["serverLogin.portDone"].waitForExistence(timeout: 5),
                      "a number pad with no way off it is a screen somebody is stuck on")
        app.buttons["serverLogin.portDone"].tap()

        let username = app.textFields["serverLogin.username"]
        username.tap()
        username.typeText("asad")

        let password = app.secureTextFields["serverLogin.password"]
        password.tap()
        password.typeText("hunter2")

        app.buttons["serverLogin.submit"].tap()

        let headline = app.staticTexts["serverLogin.errorHeadline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 60),
                      "the button must land somewhere, never on a spinner that ends nowhere")
        XCTAssertTrue(app.staticTexts["serverLogin.errorAdvice"].exists,
                      "a refusal names the next move")
        XCTAssertTrue(app.textFields["serverLogin.address"].exists,
                      "the form comes back underneath the failure, not instead of it")
        // The port survived, which is the point of it being a field: the one
        // thing somebody would go back and correct must still be there.
        XCTAssertEqual(port.value as? String, "2222")
        capture("06-refused")
    }

    /// Written beside the assertions when `TD_SHOTS` names a directory, and
    /// skipped silently when it does not — a photograph is a deliverable, not a
    /// condition of the run.
    private func capture(_ name: String) {
        let shots = env("TD_SHOTS")
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
