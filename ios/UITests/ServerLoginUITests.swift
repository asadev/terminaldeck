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

    /// The one thing that had to leave: a command to copy and go and run
    /// somewhere else. *"I don't want that command."*
    func testTheOtherDoorNoLongerHandsOutAnInstallCommand() {
        XCTAssertTrue(app.buttons["pairing.addServer"].waitForExistence(timeout: 15)
                          || app.openMachinesTab(),
                      "never reached a screen that offers a server")
        // The address door is still reachable from the pairing sheet; what is
        // gone is its footer. Nothing anywhere in this app offers the line now.
        XCTAssertFalse(app.buttons["addServer.copyInstall"].exists)
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "install.sh")).count, 0)
    }

    // MARK: - Walking

    /// `TabNavigation.swift` owns the walk — the machines stopped being a tab
    /// once already, and six suites did not have to change because of it.
    private func openTheMachinesScreen() {
        XCTAssertTrue(app.openMachinesTab(), "never reached the machines screen")
    }

    /**
     * The way in, from wherever this phone happens to be.
     *
     * On a phone with nothing on it — which is the case this feature exists for
     * — there are no tabs at all: `RootView` puts the pairing screen over the
     * whole window, and the server door is the line under the code field. On a
     * phone that already has something, it is the row on Machines. Both are real
     * first steps and a suite that knew only one of them would be testing the
     * wrong phone.
     */
    private func openTheLoginForm() {
        let fromPairing = app.buttons["pairing.addServer"]
        if fromPairing.waitForExistence(timeout: 10) {
            fromPairing.tap()
            return
        }
        openTheMachinesScreen()
        let add = app.buttons["machines.addServer"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no way in to the server login")
        add.tap()
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
