/**
 * The Add-server screen, tapped rather than described.
 *
 * ## Why this suite does not skip
 *
 * Every other case in this target needs a host on the machine and skips itself
 * when its variable is unset, because there is nothing to connect to. This one
 * needs none, and that is the point: what it proves is that the door **exists
 * and opens**, which is the whole of what 0.10.0 got wrong. The wire, the
 * driver, the host verifier and the roster all shipped and passed their tests;
 * the screen that reaches them did not exist, and no unit test can notice a
 * missing screen.
 *
 * So this walks to it the way a person does, fills the form, presses the button
 * and reads what comes back. The one path it can complete without a server is
 * the refusal — an address that cannot be parsed — and that is worth having on
 * its own: a button that leaves a spinner up forever is the failure mode this
 * screen was written against.
 *
 * The live path is the harness's: `ios/Harness/run.sh host` with sign-in served,
 * driven by `TD_SIGNIN_ADDRESS`, and the case below runs only when that is set.
 *
 * `TD_SHOTS`, when set, writes the frames beside the assertions. A screen is not
 * finished until somebody has looked at it.
 */

import UIKit
import XCTest

final class AddServerUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// The two entry points, and the form behind them.
    func testTheDoorIsReachableAndTheFormIsReal() {
        // Photograph the screen the door is on — whichever of the two this
        // phone is in front of. A door nobody can find is the whole of the
        // fault this lane exists to fix, so it is worth a frame.
        if app.buttons["pairing.addServer"].waitForExistence(timeout: 3) {
            capture("00-door-on-the-pairing-screen")
        } else if app.openMachinesTab() {
            capture("00-door-on-the-machines-list")
        }

        XCTAssertTrue(app.beginAddingAServer(),
                      "there must be a way to add a server from the machines list or the pairing screen")
        capture("01-add-server-form")

        XCTAssertTrue(app.textFields["addServer.address"].exists)
        XCTAssertTrue(app.textFields["addServer.username"].exists)
        XCTAssertTrue(app.secureTextFields["addServer.password"].exists,
                      "the password field is secure, not a plain field")
        XCTAssertTrue(app.buttons["addServer.submit"].exists)
        // The install line, for a machine with no host on it yet. A screen that
        // refused an address for a server that does not exist and explained
        // nothing would be the dead end this one is written against.
        XCTAssertTrue(app.buttons["addServer.copyInstall"].exists)

        // Put the app back where it was found. A case that leaves a sheet up is
        // a case that fails the next one for reasons nothing in it explains.
        app.buttons["addServer.done"].tap()
    }

    /// Private key rather than password: the field changes shape, because a key
    /// is forty lines and a single-line secure field eats its newlines.
    func testTheKeyOptionOffersAPasteRatherThanAOneLineField() {
        XCTAssertTrue(app.beginAddingAServer())
        app.buttons["Private key"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Private key"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["addServer.password"].exists,
                       "a key is forty lines; a single-line secure field eats its newlines")
        capture("02-add-server-key")
        app.buttons["addServer.done"].tap()
    }

    /**
     * The button ends somewhere.
     *
     * An address that cannot be parsed never opens a socket, so this completes
     * with no server anywhere — and it is the case that proves the screen cannot
     * leave a spinner up. Both halves of the answer are asserted: what went
     * wrong, and what to do about it.
     */
    func testAnUnreadableAddressIsRefusedWithSomethingToDo() {
        XCTAssertTrue(app.beginAddingAServer())

        let address = app.textFields["addServer.address"]
        address.tap()
        address.typeText("123456")

        let username = app.textFields["addServer.username"]
        username.tap()
        username.typeText("asad")

        let password = app.secureTextFields["addServer.password"]
        password.tap()
        password.typeText("hunter2")

        app.buttons["addServer.submit"].tap()

        let headline = app.staticTexts["addServer.errorHeadline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10),
                      "the button must land somewhere, never on a spinner that ends nowhere")
        XCTAssertTrue(app.staticTexts["addServer.errorAdvice"].exists,
                      "a refusal names the next move")
        // And the form is still under it, so one field can be fixed rather than
        // the whole thing started again.
        XCTAssertTrue(app.textFields["addServer.address"].exists)
        capture("03-add-server-refused")

        app.buttons["addServer.done"].tap()
    }

    /**
     * A **real** server, refusing a login it does not know.
     *
     * The half of the live path that needs no credentials, and the one that
     * proves the most per second: the address parses, a sealed channel opens to
     * a host running the product's own `server.ts`, that host's real `enroll`
     * handler answers, and its sentence lands on this screen. Everything
     * between the field and `enroll.ts` is exercised for real; only the
     * password is wrong on purpose.
     *
     * `TD_SIGNIN_ADDRESS` alone gates it — start a host with
     * `node out/headless/host.mjs` under a HOME of its own and compose the
     * address from its `remote/relay-identity.json`.
     */
    func testARealServerRefusesALoginItDoesNotKnow() throws {
        let address = env("TD_SIGNIN_ADDRESS")
        try XCTSkipIf(address.isEmpty, "needs TD_SIGNIN_ADDRESS")

        XCTAssertTrue(app.beginAddingAServer())
        fill(address: address, user: "nobody-terminaldeck", secret: "not-the-password")
        app.buttons["addServer.submit"].tap()

        /*
         * The wait, photographed **if it is still there**.
         *
         * Not asserted, and the reason is a real property of the thing rather
         * than a flake being tolerated: `enroll.ts` rate-limits a guessing
         * address, so a host that has already refused this device once answers
         * the next attempt with no SSH probe at all — in less time than it takes
         * to run the query. A test that demanded to see the wait would fail on
         * the server behaving correctly. What must always be true is the line
         * below: the button lands on an answer.
         */
        if app.staticTexts["addServer.working"].waitForExistence(timeout: 3) {
            capture("05-add-server-working")
            XCTAssertEqual(app.buttons["addServer.done"].label, "Close",
                           "leaving does not stop the sign-in, so the button must not say Cancel")
            XCTAssertTrue(app.buttons["addServer.cancelSignIn"].exists, "and there is a real Stop")
        }

        let headline = app.staticTexts["addServer.errorHeadline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 90),
                      "a real host verifies against its own sshd; that takes real time")
        capture("06-add-server-real-refusal")
        // Whatever the host said, this screen says something a person can act
        // on — and it is never the address error, because the address parsed
        // and a socket really opened.
        XCTAssertNotEqual(headline.label, "That server address was not readable.")
        XCTAssertTrue(app.staticTexts["addServer.errorAdvice"].exists)
        app.buttons["addServer.done"].tap()
    }

    /**
     * The live path: a real server, a real login, a machine in the list.
     *
     * Skipped unless `TD_SIGNIN_ADDRESS` names a server address and
     * `TD_SIGNIN_USER` a login it trusts — the standing rule in this target,
     * because a laptop with nothing listening must not fail a suite.
     *
     * Two ways to hand over the secret, because the screen has two.
     * `TD_SIGNIN_SECRET` is typed into the password field. `TD_SIGNIN_KEY=1`
     * instead takes the **private key** road: the key is expected to be on the
     * simulator's pasteboard already (`xcrun simctl pbcopy`), because that
     * field deliberately has no text input at all — a forty-line key typed into
     * a single-line control arrives with its newlines eaten, and nothing on
     * this screen ever renders one.
     */
    func testSigningIntoARealServer() throws {
        let address = env("TD_SIGNIN_ADDRESS")
        let user = env("TD_SIGNIN_USER")
        let secret = env("TD_SIGNIN_SECRET")
        let byKey = env("TD_SIGNIN_KEY") == "1"
        try XCTSkipIf(address.isEmpty || user.isEmpty || (secret.isEmpty && !byKey),
                      "needs TD_SIGNIN_ADDRESS, TD_SIGNIN_USER and a secret")

        XCTAssertTrue(app.beginAddingAServer())
        if byKey {
            fill(address: address, user: user, secret: nil)
            app.buttons["Private key"].firstMatch.tap()
            let paste = app.buttons["addServer.pasteKey"]
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            paste.tap()
            XCTAssertTrue(app.staticTexts["addServer.keyReady"].waitForExistence(timeout: 10),
                          "the key must arrive whole; the row says how many characters landed")
            capture("07-add-server-key-ready")
        } else {
            fill(address: address, user: user, secret: secret)
        }
        app.buttons["addServer.submit"].tap()
        XCTAssertTrue(app.staticTexts["addServer.signedIn"].waitForExistence(timeout: 90),
                      "the server verifies the login against its own sshd; that takes real time")
        capture("04-add-server-signed-in")
        app.buttons["addServer.open"].tap()

        // And it is a machine like any other: on the list, with the two verbs
        // every other row has.
        XCTAssertTrue(app.openMachinesTab())
        capture("05-add-server-in-the-list")
    }

    /// The three fields, in order. `typeText` rather than a paste, because the
    /// system paste control cannot be driven from a test — and typing is what
    /// proves the field accepts the whole blob rather than a trimmed one.
    private func fill(address: String, user: String, secret: String?) {
        let addressField = app.textFields["addServer.address"]
        addressField.tap()
        addressField.typeText(address)
        let userField = app.textFields["addServer.username"]
        userField.tap()
        userField.typeText(user)
        guard let secret else { return }
        let secretField = app.secureTextFields["addServer.password"]
        secretField.tap()
        secretField.typeText(secret)
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
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
