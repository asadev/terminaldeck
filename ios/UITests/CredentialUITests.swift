/**
 * Somebody else's `git push`, answered on this phone, with a finger.
 *
 * `CredentialResponderTests` proves the policy and `CredentialWireTests` proves
 * the frames. Neither can prove the thing this feature actually is: that a
 * question asked by a **machine over the sealed channel** arrives here, becomes a
 * prompt that names the right three things, and that a tap on it becomes an
 * answer that machine receives. Every step of that involves a socket, a relay,
 * a Keychain and a view, and none of them are reachable from a unit test.
 *
 * This is also the guard against the failure this repository cares most about:
 * built, but never wired to boot. Nothing below presses a button to *enable*
 * anything. The app is launched, a machine asks, and the app answers — or it
 * does not, and this goes red.
 *
 * ## What stands in for what
 *
 * The machine is `ios/Harness/run.sh host`, which is the real relay, the real
 * sealed channel and the real protocol parser, with a `/credential` control
 * endpoint that plays the part `credentials.ts` plays on a desktop: it asks, and
 * it reports what came back. It cannot hand a login to anything, because it is
 * not running `git` — what it reports is the phone's half, which is the half
 * under test.
 *
 * GitHub is `ios/Harness/fake-github.mjs`. The alternative to standing it in is
 * keeping a real token in the repository or writing a back door that puts one in
 * the Keychain, and the seam that points the app at it does not exist in a
 * Release build at all. See `GitHubEndpoints`.
 *
 * ## Running it
 *
 *     node ios/Harness/fake-github.mjs --port 8799 &
 *     ios/Harness/run.sh host --port 8797 --approve-after 2000 &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17' \
 *       -only-testing:TerminalDeckUITests/CredentialUITests \
 *       TEST_RUNNER_TD_CREDENTIAL_CONTROL=127.0.0.1:8798 \
 *       TEST_RUNNER_TD_GITHUB_BASE=http://127.0.0.1:8799
 *
 * Skips rather than fails when there is nothing to talk to, like every other UI
 * suite here.
 */

import XCTest

final class CredentialUITests: XCTestCase {

    private var app: XCUIApplication!

    /// The stand-in desktop's control server, e.g. `127.0.0.1:8798`.
    ///
    /// Its own variable rather than `TD_CONTROL`, which `InspectUITests` reads.
    /// The two suites need *different* programs behind that address — only
    /// `host-standin.ts` serves `/credential`, only `scripts/remote-host.ts`
    /// serves tunnels — so sharing the name would mean one invocation could
    /// never configure both, and whichever suite lost would fail rather than
    /// skip.
    ///
    /// It is an address rather than a pairing link because a pairing token is
    /// worth sixty seconds, and one handed over when the process started has
    /// expired by the time the Simulator has booted — the same trap
    /// `InspectUITests` documents. The code is minted at the moment it is used.
    private var control: String { ProcessInfo.processInfo.environment["TD_CREDENTIAL_CONTROL"] ?? "" }
    /// Where the app should look for GitHub. Read here and forwarded into the
    /// app's own environment, which is the only way it can be set.
    private var gitHubBase: String { ProcessInfo.processInfo.environment["TD_GITHUB_BASE"] ?? "" }

    /// What the machine is renamed to, so the prompt's third line can be
    /// asserted against something a person chose rather than against a base32
    /// host id that means nothing to anybody.
    private static let machineName = "Harness Mac"
    private static let repo = "asadev/terminaldeck"

    private static let notRunning =
        "This needs ios/Harness/run.sh host and ios/Harness/fake-github.mjs. See the top of this file, "
        + "and pass TEST_RUNNER_TD_CREDENTIAL_CONTROL and TEST_RUNNER_TD_GITHUB_BASE."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(control.isEmpty || gitHubBase.isEmpty, Self.notRunning)

        app = XCUIApplication()
        app.launchEnvironment["TD_GITHUB_BASE"] = gitHubBase
        app.launch()

        // Pairings outlive the process — they are in the Keychain — so without
        // this a case starts against whatever the one before it left, or against
        // a machine from last night that is no longer listening.
        forgetEveryMachine()
        try pair(freshCode())
        try XCTSkipUnless(waitForConnected(timeout: 60), "\(Self.notRunning) (never reached Connected)")
        renameMachine(to: Self.machineName)
    }

    // MARK: - The cases

    /**
     * A fetch is answered without anybody being interrupted.
     *
     * Most of what this feature does. Every fetch, pull and clone in a session
     * on somebody else's machine comes through here, and a prompt for each of
     * them would train a person to tap Approve without reading — which is the
     * one outcome that would make the prompt worthless.
     */
    func testAFetchIsAnsweredWithoutAnybodyBeingAsked() throws {
        try connectGitHub()

        let asked = ask("op=read&prompt=0")
        wait(for: [asked.done], timeout: 30)

        XCTAssertFalse(app.buttons["credential.approve"].exists,
                       "a read must never raise a prompt")
        XCTAssertEqual(asked.answeredAs, "harness-user",
                       "the machine should have been answered: \(asked.summary)")
        XCTAssertGreaterThan(asked.secretBytes, 0, "an answer with no secret in it is not an answer")
        XCTAssertFalse(asked.remembered, "nobody was asked, so nothing was agreed to")
    }

    /**
     * With no GitHub connected, the machine is told that — and told it is not a
     * refusal.
     *
     * `no-account` and `denied` are different things to be told and have
     * different fixes, and the desktop writes a different sentence into its own
     * terminal for each. Reporting one as the other sends somebody looking for a
     * person who said no.
     */
    func testAMachineIsToldWhenNoGitHubIsConnected() throws {
        disconnectGitHub()

        let asked = ask("repo=\(Self.repo)&prompt=1")
        wait(for: [asked.done], timeout: 30)

        XCTAssertFalse(app.buttons["credential.approve"].exists,
                       "there is nothing to ask a person about with no account connected")
        XCTAssertEqual(asked.denied, "no-account", asked.summary)
    }

    /**
     * A push raises the prompt, and the prompt names the three things.
     *
     * The repository, the account, and **the machine that asked, by name**. That
     * last line is the one the whole feature turns on: "approve a push" is not a
     * question anybody can answer, and "approve a push from Harness Mac" is.
     */
    func testAPushRaisesAPromptNamingTheRepoTheAccountAndTheMachine() throws {
        try connectGitHub()

        let asked = ask("repo=\(Self.repo)&prompt=1&wait=60000")

        // Asked about by its Approve button rather than by a container
        // identifier. An identifier on a `VStack` is not an element XCUITest can
        // find — that query resolved to nothing while the prompt was on screen,
        // and the failure read as the sheet never appearing. See the note in
        // `CredentialPromptView`.
        let prompt = app.buttons["credential.approve"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 25),
                      "the machine asked and nothing appeared on the phone")
        XCTAssertTrue(app.staticTexts[Self.repo].waitForExistence(timeout: 5),
                      "the prompt must name the repository it is approving")
        XCTAssertTrue(app.staticTexts["@harness-user"].exists,
                      "the prompt must name whose account goes on the commit")
        XCTAssertTrue(app.staticTexts[Self.machineName].exists,
                      "the prompt must name the machine that asked")

        add(screenshot(named: "credential prompt"))

        prompt.tap()
        wait(for: [asked.done], timeout: 30)

        XCTAssertEqual(asked.answeredAs, "harness-user", asked.summary)
        XCTAssertFalse(asked.remembered, "Approve is once; Always is the other button")
        XCTAssertFalse(prompt.exists, "the prompt should go once it has been answered")
    }

    /**
     * "Always for this repo" is a different answer, and it says so on the wire.
     *
     * It is a *scope*, not a stored secret: the machine may stop asking about
     * this repository from this device, and every push still comes back here for
     * the credential. The difference between the two taps is the entire consent
     * model, so it is asserted rather than assumed.
     */
    func testAlwaysForThisRepoIsSentAsTheStandingScope() throws {
        try connectGitHub()

        let asked = ask("repo=\(Self.repo)&prompt=1&wait=60000")
        XCTAssertTrue(app.buttons["credential.approve"].waitForExistence(timeout: 25),
                      "the machine asked and nothing appeared on the phone")
        app.buttons["credential.approveAlways"].tap()
        wait(for: [asked.done], timeout: 30)

        XCTAssertEqual(asked.answeredAs, "harness-user", asked.summary)
        XCTAssertTrue(asked.remembered, "the second button has to reach the machine as remember")
    }

    /**
     * Deny reaches the machine as a code rather than as silence.
     *
     * Silence is the same shape as a phone in a drawer, and the desktop answers
     * that by waiting out a deadline. A refusal somebody made on purpose has to
     * be immediate, or the feature's worst-looking failure is the one a person
     * chose.
     */
    func testDenyReachesTheMachineImmediately() throws {
        try connectGitHub()

        let asked = ask("repo=\(Self.repo)&prompt=1&wait=60000")
        XCTAssertTrue(app.buttons["credential.approve"].waitForExistence(timeout: 25),
                      "the machine asked and nothing appeared on the phone")
        app.buttons["credential.deny"].tap()
        wait(for: [asked.done], timeout: 30)

        XCTAssertEqual(asked.denied, "denied", asked.summary)
    }

    /**
     * A prompt that cannot name the repository says so, and does not offer to
     * remember one.
     *
     * The desktop sends nil when git gave it no path to derive a name from. This
     * is the one screen in the feature that exists to tell the truth about what
     * is being approved, so it must not invent a name — and there is nothing to
     * attach "always" to, which is why the second button is not there.
     */
    func testAnUnnamedRepositoryIsSaidRatherThanInvented() throws {
        try connectGitHub()

        let asked = ask("repo=&prompt=1&wait=60000")
        XCTAssertTrue(app.buttons["credential.approve"].waitForExistence(timeout: 25),
                      "the machine asked and nothing appeared on the phone")
        XCTAssertTrue(app.staticTexts["Push to a repository on github.com?"].exists,
                      "the prompt should say it cannot name the repository")
        XCTAssertFalse(app.buttons["credential.approveAlways"].exists,
                       "there is no repository to remember")

        app.buttons["credential.approve"].tap()
        wait(for: [asked.done], timeout: 30)
        XCTAssertEqual(asked.answeredAs, "harness-user", asked.summary)
    }

    // MARK: - The account

    private func connectGitHub() throws {
        openGitHub()
        // Evidence, attached from inside so a run is self-contained when nobody
        // is watching: this screen is where the account comes from and it is the
        // one deliberately short of words — the approval prompt is the whole
        // explanation of this feature, so nothing here repeats it.
        add(screenshot(named: "github account"))
        if app.staticTexts["github.login"].exists {
            app.buttons["github.done"].tap()
            return
        }
        app.buttons["github.useTokenInstead"].tap()
        let field = app.secureTextFields["github.tokenField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the token field should appear")
        field.tap()
        // Opaque to this app by design: what makes it an account is GitHub's
        // answer to `GET /user`, which is where the login on the prompt comes
        // from. The stand-in returns a name this string does not contain, so a
        // prompt that echoed the typed value could not pass.
        field.typeText("ghp_harness_pasted_token")
        app.buttons["github.useToken"].tap()

        XCTAssertTrue(app.staticTexts["github.login"].waitForExistence(timeout: 20),
                      "the account should appear once GitHub has named it")
        XCTAssertEqual(app.staticTexts["github.login"].label, "@harness-user",
                       "the name must be the one GitHub gave, not the one typed")
        app.buttons["github.done"].tap()
    }

    private func disconnectGitHub() {
        openGitHub()
        if app.buttons["github.disconnect"].waitForExistence(timeout: 5) {
            app.buttons["github.disconnect"].tap()
        }
        app.buttons["github.done"].tap()
    }

    private func openGitHub() {
        let more = app.buttons["sessions.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the overflow menu should be on the list")
        more.tap()
        let item = app.buttons["sessions.github"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu should offer the GitHub account")
        item.tap()
        XCTAssertTrue(app.buttons["github.done"].waitForExistence(timeout: 10),
                      "the GitHub screen should open")
    }

    // MARK: - Being the machine that asks

    /// What one `/credential` call came back with, filled in when it answers.
    private final class Asked {
        let done = XCTestExpectation(description: "the machine heard back")
        var rows: [[String: Any]] = []

        private var first: [String: Any]? { rows.first }
        private var answer: [String: Any]? { first?["answer"] as? [String: Any] }

        var answeredAs: String? { answer?["username"] as? String }
        var secretBytes: Int { (answer?["secretBytes"] as? NSNumber)?.intValue ?? 0 }
        var remembered: Bool { (answer?["remember"] as? NSNumber)?.boolValue ?? false }
        var denied: String? { first?["denied"] as? String }
        /// For a failure message. Never carries a secret — the harness reports
        /// the length of one and never the bytes.
        var summary: String { "the machine saw: \(rows)" }
    }

    /**
     * Be the `git` that needs a login.
     *
     * Fired and **not** waited on, because the interesting cases need the
     * request to be in flight while a finger presses one of three buttons. The
     * caller waits on `done` once it has done that.
     */
    private func ask(_ query: String) -> Asked {
        let asked = Asked()
        guard let url = URL(string: "http://\(control)/credential?\(query)") else {
            XCTFail("\(control) is not an address")
            asked.done.fulfill()
            return asked
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = json["asked"] as? [[String: Any]] {
                asked.rows = rows
            }
            asked.done.fulfill()
        }.resume()
        return asked
    }

    // MARK: - Pairing

    private func forgetEveryMachine() {
        for _ in 0 ..< 6 {
            guard app.buttons["sessions.more"].waitForExistence(timeout: 3) else { return }
            app.buttons["sessions.more"].tap()
            let forget = app.buttons["sessions.unpair"]
            guard forget.waitForExistence(timeout: 3) else {
                app.tap()
                return
            }
            forget.tap()
            _ = app.textFields["pairing.field"].waitForExistence(timeout: 3)
        }
    }

    /// Mint a code on the machine, now. A pairing token is worth sixty seconds.
    private func freshCode() throws -> String {
        guard let url = URL(string: "http://\(control)/pair") else {
            throw XCTSkip("\(control) is not an address")
        }
        var answer: String?
        let minted = expectation(description: "minted")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                answer = json["uri"] as? String
            }
            minted.fulfill()
        }.resume()
        wait(for: [minted], timeout: 20)
        guard let answer, !answer.isEmpty else {
            throw XCTSkip("\(Self.notRunning) (\(control) did not answer /pair)")
        }
        return answer
    }

    /// Typed rather than opened as a link: `simctl openurl` raises a system
    /// confirmation nothing in XCUITest can reach, and typing is the same code
    /// path from `pair(with:)` onwards.
    private func pair(_ code: String) throws {
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the pairing screen should be up")
        field.tap()
        field.typeText(code)
        app.buttons["pairing.submit"].tap()
    }

    /**
     * Give the machine a name, so the prompt's third line can be checked against
     * something somebody chose.
     *
     * Driven exactly the way `MultiHostUITests` drives it, including the two
     * things that cost it a night: the alert lives in a window of its own so the
     * query has to be scoped to it, and the field carries no identifier because
     * SwiftUI drops it on the way to `UIAlertController`.
     */
    private func renameMachine(to name: String) {
        let more = app.buttons["sessions.more"]
        guard more.waitForExistence(timeout: 20) else { return }
        more.tap()
        let rename = app.buttons["sessions.rename"]
        guard rename.waitForExistence(timeout: 10) else { return }
        rename.tap()

        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 10) else { return }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { return }
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText(name)
        // `.firstMatch`, because SwiftUI nests the alert's button inside a button
        // of the same identifier and a bare subscript throws on the ambiguity.
        alert.buttons["rename.save"].firstMatch.tap()
    }

    // MARK: - Helpers

    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }

    private func screenshot(named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
