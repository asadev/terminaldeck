/**
 * Logging in to a **real server** from the phone, and photographing what comes
 * back.
 *
 * ## Why this suite is not a fixture walk
 *
 * The half of this feature worth checking is the half a fixture cannot produce:
 * an SSH handshake against somebody's sshd, a host key that has to match what
 * `ssh-keyscan` prints, and a survey of a machine nobody wrote down in advance.
 * The unit tests cover the readers against captured output; this covers the
 * thing that produces the output.
 *
 * So it takes a real server out of the environment and skips when it has none —
 * this target's standing rule. Nothing here is checked in and nothing is
 * remembered: the address, the account and the key live in `SIMCTL_CHILD_…`
 * variables for the length of one test process.
 *
 *     TD_SERVER_ADDRESS=… TD_SERVER_PORT=22 TD_SERVER_USER=root \
 *     TD_SERVER_KEY_BASE64="$(base64 < ~/.ssh/id_ed25519)" TD_SHOTS=/tmp/shots \
 *     xcodebuild test -only-testing:TerminalDeckUITests/ServerLoginUITests …
 *
 * **Read-only.** The walk logs in, looks, and photographs. It does not install,
 * start or stop anything, because the machine on the other end is somebody's and
 * a test suite has no business changing it.
 */

import XCTest

final class ServerLoginUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let address = env("TD_SERVER_ADDRESS")
        try XCTSkipIf(address.isEmpty, "No TD_SERVER_ADDRESS: nothing real to log in to.")
        app = XCUIApplication()
        app.launchEnvironment["TD_SERVER_ADDRESS"] = address
        app.launchEnvironment["TD_SERVER_PORT"] = env("TD_SERVER_PORT")
        app.launchEnvironment["TD_SERVER_USER"] = env("TD_SERVER_USER")
        app.launchEnvironment["TD_SERVER_KEY_BASE64"] = env("TD_SERVER_KEY_BASE64")
        app.launchEnvironment["TD_SERVER_PASSWORD"] = env("TD_SERVER_PASSWORD")
        app.launch()
    }

    /**
     * The whole of what he asked for, in the order he asked for it: log in,
     * then everything about that server, then whether the host is on it.
     */
    func testLogsInToARealServerAndShowsWhatIsOnIt() throws {
        openTheLoginForm()
        shoot("server-login-form")

        // The fields arrive filled from the environment — see the note on
        // `ServerLoginView.prefillFromEnvironment`.
        XCTAssertTrue(app.textFields["serverLogin.address"].exists)
        // Asserted before the tap, because a disabled button swallows one
        // silently and the walk then waits out its whole timeout for a screen
        // nothing was ever going to reach. That is exactly how the key arriving
        // empty presented the first time.
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled,
                      "the form is not complete, so Log in cannot be pressed")
        app.buttons["serverLogin.submit"].tap()

        let signedIn = app.staticTexts["serverLogin.signedIn"]
        XCTAssertTrue(signedIn.waitForExistence(timeout: 60),
                      "the login never finished: "
                          + (app.staticTexts["serverLogin.errorHeadline"].label))

        // The fingerprint is shown once, at the only moment it can be checked.
        XCTAssertTrue(app.staticTexts["serverLogin.fingerprint"].label.hasPrefix("SHA256:"))
        shoot("server-login-signed-in")

        app.buttons["serverLogin.open"].tap()

        // The server's own page — reached without a further tap, because a phone
        // whose only machine is this server has nothing else to be looking at.
        // *"Then all the server-related stuff comes up."*
        let hostLine = app.staticTexts["server.hostLine"]
        XCTAssertTrue(hostLine.waitForExistence(timeout: 60), "the server page never measured")
        shoot("server-page-top")

        XCTAssertTrue(app.staticTexts["server.where"].exists)
        XCTAssertTrue(app.staticTexts["server.serviceCount"].waitForExistence(timeout: 10),
                      "the machine answered no services at all, which no systemd box does")
        XCTAssertTrue(app.staticTexts["server.measured"].exists,
                      "a page that never refreshes has to say when it last looked")

        app.swipeUp()
        shoot("server-page-machine")
        app.swipeUp()
        shoot("server-page-running")

        // And the list it came from: a server is a row beside the machines,
        // clearly not one of them. A phone that has *only* servers is exactly
        // the phone this whole flow is for, so it is worth a frame.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["machines.server"].firstMatch.waitForExistence(timeout: 10),
                      "the server is not on the machines list")
        shoot("machines-with-a-server")
    }

    /**
     * The check-and-install step, right where he asked for it.
     *
     * > *"Right after logging in we need to have the step for
     * > checking/installing headless Terminal Deck."*
     *
     * So this does not leave the login screen. After the receipt it reads the
     * host card that is *on that screen* and asserts one of the four honest
     * answers is drawn: a host that is running and can be connected to, one that
     * is installed and stopped, one that is not there at all with an Install
     * button, or a stated reason why it cannot go on this machine. Which of the
     * four depends on the server, and all four are correct outcomes — what is
     * not correct is none of them.
     */
    func testTheCheckAndInstallStepIsPartOfTheLogin() throws {
        openTheLoginForm()
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled)
        app.buttons["serverLogin.submit"].tap()

        XCTAssertTrue(app.staticTexts["serverLogin.signedIn"].waitForExistence(timeout: 60),
                      "the login never finished: "
                          + app.staticTexts["serverLogin.errorHeadline"].label)

        // The step, on this screen, without going anywhere to find it.
        let hostLine = app.staticTexts["server.hostLine"]
        XCTAssertTrue(hostLine.waitForExistence(timeout: 60),
                      "the check step is not on the login screen")
        shoot("login-step-host")

        let offered = app.buttons["server.install"].exists
            || app.buttons["server.connect"].exists
            || app.buttons["server.startConnect"].exists
            || app.buttons["server.disconnect"].exists
            || app.staticTexts["server.hostRefusal"].exists
        XCTAssertTrue(offered,
                      "the step said \"\(hostLine.label)\" and offered nothing to do about it")

        // And never a command to copy and go and run somewhere else.
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "install.sh")).count, 0)
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "curl")).count, 0)
    }

    /**
     * **The whole of it, on a bare server**: log in, be offered Face ID, be told
     * there is no host here, install one, and connect — without leaving this
     * screen and without a command to copy.
     *
     * > *"If it does not exist, it gives the option to install — you click, it
     * > installs, then you can connect, and disconnect if you want."*
     *
     * Gated on `TD_SERVER_MAY_INSTALL=1` on top of the usual variables, because
     * this one **changes the far end**: it puts the headless host into that
     * account's home folder. Every other case in this file is read-only against
     * somebody's machine, and that default does not move for a screenshot.
     *
     *     TD_SERVER_ADDRESS=… TD_SERVER_USER=root \
     *     TD_SERVER_KEY_BASE64="$(base64 < ~/.ssh/id_ed25519)" \
     *     TD_SERVER_MAY_INSTALL=1 TD_SHOTS=/tmp/shots xcodebuild test …
     */
    func testInstallsOntoABareServerAndConnects() throws {
        try XCTSkipIf(env("TD_SERVER_MAY_INSTALL") != "1",
                      "this case installs software on the far end; opt in explicitly")

        openTheLoginForm()
        shoot("live-01-form-filled")
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled)
        app.buttons["serverLogin.submit"].tap()

        /*
         * Three minutes, and the failure says what was on screen.
         *
         * A login here is a real SSH handshake followed by two probe scripts
         * over the same connection, and a small VPS on the other side of the
         * world takes as long as it takes. The first version waited 90 seconds
         * and then tried to read `serverLogin.errorHeadline` to explain itself —
         * which does not exist while the screen is still *working*, so the
         * timeout came back as "no matches found for predicate" and said nothing
         * about the app at all. `whatIsOnScreen` reads only what is there.
         */
        let signedIn = app.staticTexts["serverLogin.signedIn"].waitForExistence(timeout: 180)
        shoot("live-02-after-login")
        XCTAssertTrue(signedIn, "the login never finished — " + whatIsOnScreen())

        // The receipt and the check step are one screen.
        XCTAssertTrue(app.staticTexts["server.hostLine"].waitForExistence(timeout: 120),
                      "the check step never ran — " + whatIsOnScreen())
        shoot("live-02-logged-in-and-checked")

        // Nothing is offered after a login any more, and this is the assertion
        // that says so. The Face ID card that used to sit between the receipt
        // and the check step locked *this server's* password, which meant a
        // prompt on every connection to it — a prompt on every launch, in
        // practice. The lock is one switch on the main Settings page now and
        // this screen mentions it nowhere.
        XCTAssertFalse(app.staticTexts["biometry.offer"].exists,
                       "the per-server Face ID offer is gone — " + whatIsOnScreen())

        let install = app.buttons["server.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 30),
                      "a bare server must be offered an install, not a command — "
                          + whatIsOnScreen())
        shoot("live-04-no-host-yet")
        install.tap()

        // Progress, watched. The line is written by the connector, never by a
        // view, so this is the real one.
        XCTAssertTrue(app.staticTexts["server.installLine"].waitForExistence(timeout: 30))
        shoot("live-05-installing")

        /*
         * Twelve minutes, and that is not padding.
         *
         * A server with no Node 22 fetches a runtime and checks it against
         * Node's own checksum, and node-pty ships no Linux binary so it
         * compiles. `ServerConnector.installTimeout` is the same twelve minutes;
         * a shorter wait here would fail the test on an install that is working.
         */
        let finished = app.buttons["server.connect"].waitForExistence(timeout: 800)
            || app.buttons["server.startConnect"].waitForExistence(timeout: 5)
        shoot("live-06-after-install")
        XCTAssertTrue(finished, "the install did not end in something to press — " + whatIsOnScreen())

        if app.buttons["server.startConnect"].exists {
            app.buttons["server.startConnect"].tap()
        } else {
            app.buttons["server.connect"].tap()
        }

        let connected = app.staticTexts["serverLogin.connected"].waitForExistence(timeout: 120)
        shoot("live-07-connected")
        XCTAssertTrue(connected, "connect ended nowhere — " + whatIsOnScreen())
    }

    /**
     * Everything readable on screen, for a failure message.
     *
     * Written because the obvious thing — naming the label you *expected* — is
     * exactly what cannot be read when the expectation failed: XCUITest throws
     * "no matches found for predicate" and the reason for the failure is
     * replaced by a complaint about the failure message. This asks for what is
     * there.
     */
    private func whatIsOnScreen() -> String {
        let labels = app.staticTexts.allElementsBoundByIndex
            .prefix(14)
            .map(\.label)
            .filter { !$0.isEmpty }
        return labels.isEmpty ? "nothing readable on screen" : labels.joined(separator: " | ")
    }

    // MARK: - Walking

    /// `TabNavigation.swift` owns the walk — and there is one of it now, because
    /// there is one login screen. On a phone with nothing on it the login *is*
    /// the window, so there is nothing to tap.
    private func openTheLoginForm() {
        XCTAssertTrue(app.beginLoggingIntoAServer(), "no way in to the server login")
    }

    private func shoot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = env("TD_SHOTS")
        guard !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    }

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }
}
