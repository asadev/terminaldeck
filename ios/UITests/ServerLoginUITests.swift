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
 * **Read-only by default.** The walk logs in, looks, and photographs. The three
 * cases that change the far end — install, start, disconnect-and-reconnect — are
 * each behind their own opt-in variable, because the machine on the other end is
 * somebody's and a test suite has no business changing it unasked.
 *
 * ## Why every case launches the app itself
 *
 * Two of these cases are about a login that is *wrong* — a key the server never
 * accepted, a port nothing listens on — and the only way to produce one is to
 * hand the app different values than the rest of the suite gets. The launch
 * environment is fixed at launch, so `setUp` gathers what the run was given and
 * each case launches with it, overriding the one field it is about. A single
 * shared launch in `setUp` would have meant a second suite, or a back door in
 * the app for typing a wrong password, and both are worse.
 *
 * `ios/Harness/live-server.sh` is the whole of it as one command, in the order
 * Asad asked for: a bare server, a server that already has it, disconnect and
 * connect again, and the two refusals.
 */

import XCTest

final class ServerLoginUITests: XCTestCase {

    private var app: XCUIApplication!
    /// What the run was given, before any case bends one field of it.
    private var given: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let address = env("TD_SERVER_ADDRESS")
        try XCTSkipIf(address.isEmpty, "No TD_SERVER_ADDRESS: nothing real to log in to.")
        given = [
            "TD_SERVER_ADDRESS": address,
            "TD_SERVER_PORT": env("TD_SERVER_PORT"),
            "TD_SERVER_USER": env("TD_SERVER_USER"),
            "TD_SERVER_KEY_BASE64": env("TD_SERVER_KEY_BASE64"),
            "TD_SERVER_PASSWORD": env("TD_SERVER_PASSWORD"),
            // Debug-only: a host build being tried before it is published. See
            // `ServerScripts.packageToInstall`.
            "TD_SERVER_HOST_PACKAGE": env("TD_SERVER_HOST_PACKAGE"),
        ]
    }

    /// Launch with what the run was given, with `changed` written over the top.
    @discardableResult
    private func launchApp(_ changed: [String: String] = [:]) -> XCUIApplication {
        app = XCUIApplication()
        for (name, value) in given.merging(changed, uniquingKeysWith: { _, new in new }) {
            app.launchEnvironment[name] = value
        }
        app.launch()
        return app
    }

    /**
     * The whole of what he asked for, in the order he asked for it: log in,
     * then everything about that server, then whether the host is on it.
     */
    func testLogsInToARealServerAndShowsWhatIsOnIt() throws {
        launchApp()
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
        launchApp()
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

        launchApp()
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

        // And the point of all of it: a shell on that machine, on this phone.
        proveAShellOnThatMachine("live-08")
    }

    /**
     * **A server that already has it**: log in, be told it is there, bring it
     * up, connect.
     *
     * > *"It will check if the headless Terminal Deck exists on the server — if
     * > it exists it brings it up and asks you to connect."*
     *
     * The other half of the sentence the case above proves, and it is a
     * different code path rather than the same one with a flag: `HostStepCard`
     * draws Install only when the probe found nothing, and draws *either* "Start
     * it and connect" or "Connect" when it found something — which of the two
     * depends on whether the host is running, and both are correct answers to
     * "it exists". What would not be correct is an Install button on a machine
     * that already has one, so that is asserted rather than assumed.
     *
     * `TD_SERVER_HAS_HOST=1`, because a server that has *not* got the host
     * cannot pass this and skipping is the honest outcome rather than a failure
     * about the far end.
     */
    func testAServerThatAlreadyHasTheHostIsBroughtUpAndConnected() throws {
        try XCTSkipIf(env("TD_SERVER_HAS_HOST") != "1",
                      "this case needs a server that already has the host on it")

        launchApp()
        openTheLoginForm()
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled)
        app.buttons["serverLogin.submit"].tap()

        XCTAssertTrue(app.staticTexts["serverLogin.signedIn"].waitForExistence(timeout: 180),
                      "the login never finished — " + whatIsOnScreen())
        let hostLine = app.staticTexts["server.hostLine"]
        XCTAssertTrue(hostLine.waitForExistence(timeout: 120),
                      "the check step never ran — " + whatIsOnScreen())
        shoot("has-01-it-is-there")

        // It said so, in a sentence about a host that is present.
        XCTAssertFalse(app.buttons["server.install"].exists,
                       "offered to install onto a machine that already has it: \(hostLine.label)")

        let bringUp = app.buttons["server.startConnect"]
        let connect = app.buttons["server.connect"]
        let offered = bringUp.waitForExistence(timeout: 30) || connect.waitForExistence(timeout: 5)
        XCTAssertTrue(offered,
                      "it found the host and offered no way to use it — " + whatIsOnScreen())
        shoot("has-02-offered")

        if bringUp.exists { bringUp.tap() } else { connect.tap() }

        XCTAssertTrue(app.staticTexts["serverLogin.connected"].waitForExistence(timeout: 180),
                      "connect ended nowhere — " + whatIsOnScreen())
        shoot("has-03-connected")
    }

    /**
     * **Disconnect, and connect again.**
     *
     * > *"…then you can connect, and disconnect if you want."*
     *
     * Disconnect is on the server's own page rather than on the login, because
     * the login has already turned into a receipt by the time there is anything
     * to disconnect — so this walks there the way a person would: Settings, the
     * server under Servers, the same host card. What it is really checking is
     * that unpairing leaves the server *usable*: the card has to come back
     * offering a connect rather than an install, and the second connect has to
     * work without signing in to the server again.
     */
    func testDisconnectsFromTheServerAndConnectsAgain() throws {
        try XCTSkipIf(env("TD_SERVER_MAY_CONNECT") != "1",
                      "this case pairs and unpairs this phone with the far end; opt in explicitly")

        launchApp()
        openTheLoginForm()
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled,
                      "the form is not complete, so Log in cannot be pressed")
        app.buttons["serverLogin.submit"].tap()
        XCTAssertTrue(app.staticTexts["serverLogin.signedIn"].waitForExistence(timeout: 180),
                      "the login never finished — " + whatIsOnScreen())
        XCTAssertTrue(app.staticTexts["server.hostLine"].waitForExistence(timeout: 120),
                      "the check step never ran — " + whatIsOnScreen())

        // The server's own page, which is where Disconnect lives: by the time
        // there is anything to disconnect the login has turned into a receipt.
        app.buttons["serverLogin.open"].tap()
        XCTAssertTrue(app.staticTexts["server.hostLine"].waitForExistence(timeout: 60),
                      "the server's own page never opened — " + whatIsOnScreen())

        /*
         * Connected, from whichever state this phone happens to be in.
         *
         * Deliberately not "connect, then disconnect, then connect": a phone
         * that is already connected to this server is a normal way to arrive at
         * this screen, and a case that could only start from one of the two
         * would be describing a fixture rather than the product. What is being
         * checked is the *cycle*, and it starts wherever the phone is.
         */
        if !app.buttons["server.disconnect"].exists {
            let connect = app.buttons["server.connect"]
            let bringUp = app.buttons["server.startConnect"]
            guard connect.waitForExistence(timeout: 30) || bringUp.waitForExistence(timeout: 5)
            else {
                XCTFail("there is no host to connect to on this server — " + whatIsOnScreen())
                return
            }
            if connect.exists { connect.tap() } else { bringUp.tap() }
        }

        let disconnect = app.buttons["server.disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 180),
                      "a connected server offers no way to disconnect — " + whatIsOnScreen())
        shoot("cycle-01-connected")
        disconnect.tap()

        // Back to a server that is there, and not connected to.
        let connect = app.buttons["server.connect"]
        let bringUp = app.buttons["server.startConnect"]
        let again = connect.waitForExistence(timeout: 60) || bringUp.waitForExistence(timeout: 10)
        shoot("cycle-02-disconnected")
        XCTAssertTrue(again,
                      "after disconnecting there was nothing to connect with — " + whatIsOnScreen())
        XCTAssertFalse(app.buttons["server.install"].exists,
                       "disconnecting made the app forget the host is installed")

        if connect.exists { connect.tap() } else { bringUp.tap() }
        XCTAssertTrue(app.buttons["server.disconnect"].waitForExistence(timeout: 180),
                      "the second connect never landed — " + whatIsOnScreen())
        shoot("cycle-03-connected-again")
    }

    /**
     * **A prompt from that machine**, on a server that already has the host.
     *
     * The same ending as the install case and reachable without reinstalling, so
     * the last step of the flow — the one the whole feature is *for* — can be
     * driven on a server that has been set up once. `testInstallsOntoABareServerAndConnects`
     * still walks it end to end from nothing; this is the same walk from the
     * middle.
     */
    func testStartsASessionAndShowsAPromptFromThatMachine() throws {
        try XCTSkipIf(env("TD_SERVER_MAY_CONNECT") != "1",
                      "this case pairs this phone with the far end and runs a shell on it")

        launchApp()
        openTheLoginForm()
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled)
        app.buttons["serverLogin.submit"].tap()
        XCTAssertTrue(app.staticTexts["serverLogin.signedIn"].waitForExistence(timeout: 180),
                      "the login never finished — " + whatIsOnScreen())
        XCTAssertTrue(app.staticTexts["server.hostLine"].waitForExistence(timeout: 120),
                      "the check step never ran — " + whatIsOnScreen())

        let connect = app.buttons["server.connect"]
        let bringUp = app.buttons["server.startConnect"]
        guard connect.waitForExistence(timeout: 30) || bringUp.waitForExistence(timeout: 5) else {
            XCTFail("there is no host to connect to on this server — " + whatIsOnScreen())
            return
        }
        if connect.exists { connect.tap() } else { bringUp.tap() }
        XCTAssertTrue(app.staticTexts["serverLogin.connected"].waitForExistence(timeout: 180),
                      "connect ended nowhere — " + whatIsOnScreen())

        proveAShellOnThatMachine("prompt")
    }

    /**
     * **A key that server never accepted**, and what it is told.
     *
     * A real handshake against a real sshd, refused by it. The claim being
     * checked is not that something went red — it is that the sentence names
     * *this* failure and not sign-in in general. "Sign-in is not available" is
     * the shape this must never take: it is true of every failure and useful for
     * none, and it is what somebody reads instead of "your key is not on that
     * account".
     */
    func testAKeyTheServerNeverAcceptedIsRefusedInItsOwnWords() throws {
        let wrong = env("TD_SERVER_WRONG_KEY_BASE64")
        try XCTSkipIf(wrong.isEmpty, "no TD_SERVER_WRONG_KEY_BASE64 to be refused with")

        launchApp(["TD_SERVER_KEY_BASE64": wrong])
        openTheLoginForm()
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled)
        app.buttons["serverLogin.submit"].tap()

        let headline = app.staticTexts["serverLogin.errorHeadline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 120),
                      "a key the server never accepted was not refused — " + whatIsOnScreen())
        shoot("refusal-01-wrong-key")

        XCTAssertEqual(headline.label, "That sign-in was refused",
                       "the refusal does not name what happened")
        let advice = app.staticTexts["serverLogin.errorAdvice"].label
        XCTAssertTrue(advice.localizedCaseInsensitiveContains("key"),
                      "the advice never mentions the key: \(advice)")
        assertNothingVague(headline.label + " " + advice)
    }

    /**
     * **A port nothing is listening on**, and what it is told.
     *
     * The other refusal, and a different one on purpose: this one never reaches
     * a sign-in at all, so a message about passwords and keys would be a lie.
     * `SSHProblem.noAnswer` is the answer, and its advice is about the port.
     */
    func testAPortNothingListensOnIsRefusedInItsOwnWords() throws {
        let wrong = env("TD_SERVER_WRONG_PORT").isEmpty ? "2201" : env("TD_SERVER_WRONG_PORT")

        launchApp(["TD_SERVER_PORT": wrong])
        openTheLoginForm()
        XCTAssertEqual(app.textFields["serverLogin.port"].value as? String, wrong,
                       "the port under test did not reach the form")
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled)
        app.buttons["serverLogin.submit"].tap()

        let headline = app.staticTexts["serverLogin.errorHeadline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 180),
                      "a port nothing listens on was not refused — " + whatIsOnScreen())
        shoot("refusal-02-wrong-port")

        XCTAssertEqual(headline.label, "That address did not answer",
                       "the refusal does not name what happened")
        let advice = app.staticTexts["serverLogin.errorAdvice"].label
        XCTAssertTrue(advice.localizedCaseInsensitiveContains("port"),
                      "the advice never mentions the port: \(advice)")
        assertNothingVague(headline.label + " " + advice)
    }

    // MARK: - The parts the cases above are made of

    /**
     * Log in and connect, from a phone that may or may not already know this
     * server — which is the whole point of it being a helper: the case that
     * calls it is about what happens *after*.
     */
    private func connectThroughTheLogin() throws {
        openTheLoginForm()
        XCTAssertTrue(app.buttons["serverLogin.submit"].isEnabled,
                      "the form is not complete, so Log in cannot be pressed")
        app.buttons["serverLogin.submit"].tap()
        XCTAssertTrue(app.staticTexts["serverLogin.signedIn"].waitForExistence(timeout: 180),
                      "the login never finished — " + whatIsOnScreen())
        XCTAssertTrue(app.staticTexts["server.hostLine"].waitForExistence(timeout: 120),
                      "the check step never ran — " + whatIsOnScreen())

        let connect = app.buttons["server.connect"]
        let bringUp = app.buttons["server.startConnect"]
        guard connect.waitForExistence(timeout: 30) || bringUp.waitForExistence(timeout: 5) else {
            XCTFail("there is no host to connect to on this server — " + whatIsOnScreen())
            return
        }
        if connect.exists { connect.tap() } else { bringUp.tap() }
        XCTAssertTrue(app.staticTexts["serverLogin.connected"].waitForExistence(timeout: 180),
                      "connect ended nowhere — " + whatIsOnScreen())
    }

    /**
     * The server's own page, walked to the way a person reaches it.
     *
     * Not a deep link and not a launch argument: Settings holds the machines
     * now, the server is a row under them, and if that walk breaks the feature
     * is unreachable regardless of what the connector can do.
     */
    private func openServerPage() -> Bool {
        guard app.openMachinesTab() else { return false }
        let row = app.buttons["machines.server"].firstMatch
        guard row.waitForExistence(timeout: 10) else { return false }
        row.tap()
        return app.staticTexts["server.hostLine"].waitForExistence(timeout: 60)
    }

    /**
     * **A prompt from that machine**, which is the only thing any of this was
     * for.
     *
     * Nothing here reads the terminal — it is a `UIKeyInput` drawing pixels, and
     * an assertion that pretended to read it would be a worse claim than none.
     * What this does is put a command in that only that machine can answer and
     * photograph what came back, which is the same evidence a person has.
     */
    private func proveAShellOnThatMachine(_ prefix: String) {
        app.buttons["serverLogin.openMachine"].tap()
        app.openSessionsTab()

        if startASession(prefix, "a") {
            typeSomethingOnlyThatMachineCanAnswer(prefix)
            return
        }

        /*
         * **What the machine just told this phone to do.**
         *
         * *"Claude Code could not be found on this machine, so this session was
         * not started. Install it on that machine, or choose a different one in
         * its settings."* A server that this app installed the host onto a
         * minute ago has no agent CLIs on it — the installer puts a Node runtime
         * and this host on, and nothing else — so on the one machine this whole
         * feature exists for, the first New Session says that. The remedy the
         * sentence names is a real control on this phone's Settings screen, and
         * following it is the walk a person takes, so it is the walk this takes.
         */
        shoot("\(prefix)-default-tool-not-there")
        XCTAssertTrue(chooseShellAsTheMachinesDefault(prefix),
                      "the machine said to choose a different tool in its settings, and there was "
                          + "none to choose — " + whatIsOnScreen())
        app.openSessionsTab()
        XCTAssertTrue(startASession(prefix, "c"),
                      "choosing this machine's own default tool did not let a session start — "
                          + whatIsOnScreen())
        typeSomethingOnlyThatMachineCanAnswer(prefix)
    }

    /// Press New Session and answer whether a terminal came up. Both outcomes
    /// are real answers here, so this returns rather than failing.
    private func startASession(_ prefix: String, _ leg: String) -> Bool {
        let plus = app.buttons["sessions.new"]
        let fromEmpty = app.buttons["sessions.newFromEmpty"]
        guard plus.waitForExistence(timeout: 60) || fromEmpty.waitForExistence(timeout: 10) else {
            shoot("\(prefix)\(leg)-no-way-to-start-a-session")
            XCTFail("connected, and there is no way to start a session — " + whatIsOnScreen())
            return false
        }
        shoot("\(prefix)\(leg)-sessions")
        /*
         * **The toolbar's plus first, and the empty state's button only if there
         * is no plus.**
         *
         * They are not the same control. The plus opens a menu that offers the
         * folders this machine granted this phone; the button in the middle of
         * the empty state calls `createSession(in: nil)` and has no folder in it
         * at all. This walk had them the other way round, and on a server that
         * is the difference between a session and a refusal — the folder matters
         * (see the note below), and the empty list is exactly when this runs.
         */
        if !plus.exists && fromEmpty.exists {
            fromEmpty.tap()
        } else {
            plus.tap()
            /*
             * A machine that granted folders draws a menu here; one that granted
             * none starts the session on the first tap.
             *
             * **The folder is chosen when there is one**, rather than the plain
             * New Session above it, and that is not a preference. Plain New
             * Session sends no folder at all, and a host that is asked to pick
             * picks its own home directory — which on a server is the one folder
             * a session can never start in: `confine` plants the file that tests
             * the boundary in `$HOME`, so with `$HOME` *as* the boundary the
             * test cannot fail and the host refuses, correctly. Measured on a
             * real server: "the file used to test the boundary
             * (/root/.terminaldeck-confine-probe-…) is inside it, so the test
             * could not fail."
             */
            let inAFolder = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.newIn.'"))
                .firstMatch
            if inAFolder.waitForExistence(timeout: 3) {
                inAFolder.tap()
            } else {
                let menuItem = app.buttons["sessions.newDefault"]
                if menuItem.waitForExistence(timeout: 3) { menuItem.tap() }
            }
        }
        return app.buttons["terminal.keyboard"].waitForExistence(timeout: 60)
    }

    /**
     * Change the machine's own default tool to a shell, from the phone.
     *
     * These two settings belong to the machine rather than to this phone, and
     * the section says so on screen. A shell is on every machine there is, which
     * is why it is the one worth choosing on a server that has just been built.
     *
     * ## Why this does not call `openSettingsTab()`
     *
     * Because it does not work from here, and finding that out cost this walk a
     * run. That helper pops **once** — *"one Back is enough; this stack is one
     * deep by construction"* — and by this point in the case it is two deep: the
     * connect pushed Settings → Machines → the server's own page. One Back lands
     * on Machines, `settings.github` is not there, and the helper reports it
     * could not reach Settings while standing one screen away from it. So this
     * pops until it arrives, and says which screen it gave up on.
     */
    private func chooseShellAsTheMachinesDefault(_ prefix: String) -> Bool {
        app.openTab("Settings")
        var atTheRoot = false
        for _ in 0 ..< 4 {
            if app.buttons["settings.machines"].waitForExistence(timeout: 4) {
                atTheRoot = true
                break
            }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
        guard atTheRoot else { return false }

        /*
         * The section is below the machines on a phone-sized screen, and a
         * SwiftUI `ScrollView` will not always bring a control into view for a
         * tap on its own. Scrolled to rather than reached for.
         */
        let shell = app.buttons["serverSetting.provider.shell"]
        for _ in 0 ..< 5 where !shell.exists || !shell.isHittable {
            app.swipeUp()
        }
        guard shell.exists else { return false }
        shoot("\(prefix)b-machine-settings")
        shell.tap()

        /*
         * The value drawn is always the machine's own re-read — a refused apply
         * reverts by construction — so the chip becoming the selected one is the
         * machine having accepted it, not this phone having drawn it hopefully.
         */
        var took = false
        for _ in 0 ..< 20 {
            if shell.isSelected { took = true; break }
            _ = app.staticTexts["This server"].waitForExistence(timeout: 1)
        }
        shoot("\(prefix)b-default-tool-is-a-shell")
        return took
    }

    /**
     * **A prompt from that machine**, which is the only thing any of this was
     * for.
     *
     * Nothing here reads the terminal — it is a `UIKeyInput` drawing pixels, and
     * an assertion that pretended to read it would be a worse claim than none.
     * What this does is put a command in that only that machine can answer and
     * photograph what came back, which is the same evidence a person has.
     */
    private func typeSomethingOnlyThatMachineCanAnswer(_ prefix: String) {
        shoot("\(prefix)-terminal")
        app.buttons["terminal.keyboard"].tap()
        app.typeText("hostname; uname -sr; uptime\n")
        sleep(4)
        shoot("\(prefix)-shell-prompt")
    }

    /// The sentence this whole lane exists to keep out of the app: one that is
    /// true of every failure and therefore says nothing about this one.
    private func assertNothingVague(_ said: String) {
        for empty in ["not available", "something went wrong", "unknown error", "try again later"] {
            XCTAssertFalse(said.localizedCaseInsensitiveContains(empty),
                           "the refusal says \"\(empty)\", which is true of every failure: \(said)")
        }
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
