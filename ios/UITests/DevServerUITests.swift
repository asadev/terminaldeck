/**
 * A dev server started from the phone, on a real screen, against a real server.
 *
 * Nothing below can be established by a unit test, and two of the claims cannot
 * be established by reading the code at all:
 *
 *  - **A folder with no dev script draws no row.** It is the one state whose
 *    correct rendering is an *absence*, which is exactly the kind of thing that
 *    looks right in a diff and is wrong on a screen.
 *  - **The row walks idle → starting → ready on its own**, with no timer on this
 *    side. The whole feature is pushed rather than polled, so "does the row
 *    change when the far machine says something" is the feature.
 *
 * ## Running it
 *
 * The harness serves the **real** `src/main/dev-server.ts` — it reads a real
 * `package.json`, types a real command into a real PTY and only says `ready`
 * after something accepted a TCP connection — so what is needed is two folders
 * and a host pointed at them:
 *
 *     mkdir -p /tmp/td-devdemo /tmp/td-plain
 *     # /tmp/td-devdemo/package.json: { "scripts": { "dev": "node server.js" } }
 *     # /tmp/td-devdemo/server.js:    prints a few lines, then listens on 4319
 *     # /tmp/td-plain/package.json:   no dev, start or serve script
 *     ios/Harness/run.sh host --approve-after 3000 \
 *         --folders /tmp/td-devdemo,/tmp/td-plain &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/DevServerUITests
 *
 * It pairs itself off the harness's control server, the way `KeyBarUITests`
 * does, so there is no `simctl openurl` prompt to answer by hand.
 *
 * It skips rather than fails when there is nothing listening, for the reason the
 * rest of this target does: a suite that goes red on a laptop with no server
 * running is a suite that gets deleted in a week.
 *
 * ## Give it a host that has not already started the server
 *
 * There is no stop verb in this feature — a dev server is an ordinary session,
 * and stopping one is Ctrl-C in it — so a second run of this suite finds the
 * project already `ready` and the idle → starting → ready case skips itself
 * rather than pretending to have watched a start. Restart the harness (its PTYs
 * go with it) to get the walk back. The case names are chosen so XCTest's
 * alphabetical order runs the start *before* the tap that opens the page, which
 * is the order that leaves each case something to prove.
 *
 * ## If every case skips, the phone may be paired to a machine that has gone
 *
 * A simulator's Keychain survives uninstalling the app, so a phone paired with
 * yesterday's harness opens on the session list rather than the pairing screen
 * and never gets a chance to type a code. `xcrun simctl keychain <device> reset`
 * is what clears it.
 */

import XCTest

final class DevServerUITests: XCTestCase {

    /// The folders the harness is pointed at. Named here because every
    /// assertion below is about *these two* — one with a dev script and one
    /// without — and a suite that guessed at the folder names would pass
    /// vacuously on a machine where nothing was set up.
    private static let project = "/tmp/td-devdemo"
    private static let plain = "/tmp/td-plain"
    /// A project whose dev script runs and never binds a port — a misconfigured
    /// checkout, from the phone's point of view. It is the only honest way to
    /// reach `failed` here: the desktop waits out its ninety seconds, proves
    /// nothing accepted a connection, and says so.
    private static let broken = "/tmp/td-devfail"

    /// The port `/tmp/td-devdemo/server.js` binds. One number, in one place,
    /// because it has to be the same on both sides of the tunnel — that is the
    /// feature. A number chosen independently of the thing that serves it is a
    /// suite that fails on a machine where everything works; `LocalhostUITests`
    /// learned that the expensive way.
    private static let port = 4319

    /// Where `ios/Harness/run.sh host` puts its control server: the relay's
    /// port plus one.
    private static let control = URL(string: "http://127.0.0.1:8788")!

    private var app: XCUIApplication!
    private static var reachable: Bool?

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        if app.reachPairingField(timeout: 5) {
            let code = try pairingCode()
            let field = app.textFields["pairing.field"]
            field.tap()
            field.typeText(code)
            app.buttons["pairing.submit"].tap()
        }

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 15)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)

        // The dev-server rows are on the Localhost tab now rather than under the
        // sessions. See `DeckModel.Tab` for why the list moved.
        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")
    }

    private static let notRunning =
        "No harness. Start ios/Harness/run.sh host --approve-after 3000 "
        + "--folders /tmp/td-devdemo,/tmp/td-plain and run again."

    // MARK: - The rows

    /**
     * A project that can be started has a row; one that cannot does not.
     *
     * The absence is the assertion that matters. `no-dev-script` means there is
     * nothing to press and there never will be for that folder, so a row for it
     * could only carry a button whose single possible outcome is a refusal —
     * and the way that bug ships is by looking completely reasonable in the
     * code that filters it.
     */
    func testOnlyAFolderWithADevScriptGetsARow() throws {
        let row = app.buttons["devserver.\(Self.project)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "a folder with a dev script should have a row")
        XCTAssertFalse(app.buttons["devserver.\(Self.plain)"].exists,
                       "a folder with no dev script must not be offered a button")
        save("devserver-01-idle-and-absent")
    }

    /// The idle row says the command it would run, not the word "idle". Seeing
    /// it is how somebody notices that a folder's `dev` script does something
    /// other than what they expected.
    ///
    /// Skipped against a host that has already started this project, for the
    /// reason the header gives: there is no stop verb, so a second run of this
    /// suite finds the row `ready` — and a case about the *idle* row has nothing
    /// to say about a running one. Restart the harness to get it back.
    func testAnIdleRowNamesTheCommandItWouldRun() throws {
        let detail = app.staticTexts["devserver.detail.\(Self.project)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        try XCTSkipIf(detail.label.contains("localhost:"),
                      "the server is already running; restart the harness for an idle row")
        XCTAssertTrue(detail.label.contains("run dev"),
                      "the idle row should say the command; it says \(detail.label)")
    }

    // MARK: - Starting one

    /**
     * The whole feature, end to end, with a finger.
     *
     * Tap Start; the row must go to `starting` with something moving on it, then
     * reach `ready` with an address — on its own, because every one of those
     * changes is pushed by the machine and this side has no timer asking.
     */
    func testStartingAServerWalksTheRowFromIdleToReady() throws {
        let row = app.buttons["devserver.\(Self.project)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let detail = app.staticTexts["devserver.detail.\(Self.project)"]

        // Already up from an earlier case in the same run: this suite shares one
        // host, and a second Start is answered with the state it is already in
        // rather than a second server. Nothing to prove here in that case.
        try XCTSkipIf(detail.label.contains("localhost:"),
                      "the server is already running from an earlier case")

        row.tap()

        XCTAssertTrue(app.activityIndicators["devserver.spinner.\(Self.project)"]
                        .waitForExistence(timeout: 10),
                      "a start should put something moving on the row")
        save("devserver-02-starting")

        // The server's own latest line, pushed as it changes. It is the reason
        // the wait is readable rather than a bar that could be doing anything.
        let note = app.staticTexts["devserver.note.\(Self.project)"]
        XCTAssertTrue(note.waitForExistence(timeout: 20),
                      "the row should carry the server's own output while it comes up")

        let ready = NSPredicate(format: "label CONTAINS 'localhost:'")
        expectation(for: ready, evaluatedWith: detail)
        waitForExpectations(timeout: 90)
        save("devserver-03-ready")
    }

    /**
     * A project that will not come up says why, and offers another go.
     *
     * The slowest case here by far — the desktop is not allowed to give up until
     * it has genuinely waited, which is ninety seconds — and worth every one of
     * them, because `failed` is the state a client is most likely to draw wrong.
     * The two ways to get it wrong are folding it into `idle`, which throws away
     * the reason, and leaving the spinner up forever, which is what a row does
     * when nothing pushes and nothing times out.
     *
     * `Z` in the name so XCTest's alphabetical order runs it last: it is the one
     * case that costs minutes, and a suite that spends them before its fast
     * cases have said anything is a suite nobody runs.
     */
    func testZAProjectThatNeverListensReportsWhyAndOffersAnotherGo() throws {
        let row = app.buttons["devserver.\(Self.broken)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the broken project has a dev script, so it has a row")
        let detail = app.staticTexts["devserver.detail.\(Self.broken)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))

        if !app.buttons["devserver.retry.\(Self.broken)"].exists {
            row.tap()
            // The desktop's own deadline, plus room for the shell and the scan.
            let failed = NSPredicate(format: "label CONTAINS 'accepted a connection'")
            expectation(for: failed, evaluatedWith: detail)
            waitForExpectations(timeout: 150)
        }

        XCTAssertTrue(app.buttons["devserver.retry.\(Self.broken)"].waitForExistence(timeout: 10),
                      "a failure that has a session to read should still offer another attempt")
        XCTAssertFalse(app.activityIndicators["devserver.spinner.\(Self.broken)"].exists,
                       "and nothing should still be spinning over it")
        // Brought on screen before the frame is taken. `exists` is satisfied by
        // a row scrolled under the tab bar, and a screenshot of the rows above
        // it is not evidence of anything about this one — which is what the
        // first run of this case produced.
        reveal(row)
        save("devserver-05-failed")
    }

    /**
     * A server that is up is one tap from being on the phone.
     *
     * This is the sentence the whole capability exists for: *`ready` → `port` is
     * safe to tunnel; this is how a phone opens a dev server it just started.*
     * What is checked here is that the tap carries **that port** into the
     * browser — the row's own job, and the only part of the chain this feature
     * owns.
     *
     * ## What this stops short of, and why it stops there
     *
     * The page itself. The stand-in host serves no `ports` and no `tunnel.*` at
     * all — it advertises the desktop's whole capability list because it imports
     * `CAPABILITIES` wholesale, and then answers none of those verbs — so the
     * view opens, says `connecting…`, and stays there. That is a limit of the
     * harness rather than a defect in the row, and it is why the assertion is
     * where it is: everything past `tunnel.open` belongs to `PortTunnel`, whose
     * bytes-across-the-wire proof is `LocalhostUITests` against the **real**
     * endpoint (`scripts/remote-host.sh`).
     *
     * Run this suite against that host instead and the page loads for the same
     * reason a port row's does — it is the same `openLocalhost` call, with a
     * number the machine proved rather than one a scan listed.
     */
    func testTappingAReadyRowOpensItsOwnPort() throws {
        let detail = app.staticTexts["devserver.detail.\(Self.project)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        if !detail.label.contains("localhost:") {
            app.buttons["devserver.\(Self.project)"].tap()
            let ready = NSPredicate(format: "label CONTAINS 'localhost:'")
            expectation(for: ready, evaluatedWith: detail)
            waitForExpectations(timeout: 90)
        }

        app.buttons["devserver.\(Self.project)"].tap()

        // Reload rather than Done, which no longer exists: the page on this
        // phone wears the same six controls as every other browser window, and
        // Reload is drawn as soon as the screen is — greyed while the tunnel is
        // still opening, which against this stand-in host is as far as it gets.
        XCTAssertTrue(app.buttons["localhost.reload"].waitForExistence(timeout: 20),
                      "tapping a ready row should open the browser")
        // The port, on screen, in the view that was opened. Asserted rather than
        // taken for granted because carrying the *wrong* number here is the one
        // way this tap can be subtly wrong: a dev server's absolute URLs are all
        // scoped to its own port, so a view opened on a different one half-works
        // in a way that looks like the framework being broken.
        XCTAssertTrue(namesThePort(timeout: 20),
                      "the browser should be opened on the port the machine proved")
        save("devserver-04-opened-on-its-port")

        // Out by the chevron. Popping the screen is the teardown, exactly as the
        // old Done was — see `LocalhostUITests` for the verb itself, which is
        // `Close this window` inside the `…` now.
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: - Helpers

    /// The six-digit pairing code, straight from the harness — or a skip, when
    /// there is no harness to ask.
    private func pairingCode() throws -> String {
        guard let data = try? Data(contentsOf: Self.control.appendingPathComponent("pair")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else {
            Self.reachable = false
            throw XCTSkip(Self.notRunning)
        }
        return code
    }

    /**
     * Whether the browser screen that just opened says it is on **our** port.
     *
     * This was one line — `app.staticTexts["localhost:3210"]` — and that line was
     * reading the mono address the phone's page used to print as the second line
     * of its own header. That header is gone: *"even if we remove the top header
     * of paperclip and all of this basic information might not be required from
     * the outside. We can just see and enter."* The address became a real field
     * in the bar, which is the thing he could not have before.
     *
     * So the number now appears in one of two places depending on how far the
     * tunnel got, and this asks both rather than picking one:
     *
     *  - **the address field**, once the page can be navigated. Its `value` is
     *    the whole address — `localhost:3210/`, and a path after it once the page
     *    has moved — so this is a *contains*, not an equality.
     *  - **the name at the top**, before there is a page to take a name from. It
     *    falls back to `localhost:<port>` exactly then, which is the state this
     *    case reaches against the stand-in host: it answers no `tunnel.*` at all,
     *    so the screen opens, says it is connecting, and stays there.
     *
     * Asking only the first would fail against this harness and asking only the
     * second would fail against the real one — where the page loads and the name
     * at the top becomes the page's own title. The old single line happened to
     * survive both because the header printed the address in every phase, and it
     * is exactly that line the round removed.
     *
     * A poll rather than one predicated query because the two are different kinds
     * of element — a field's `value` and a label — and a query that spans both
     * would have to be written twice anyway.
     */
    private func namesThePort(timeout: TimeInterval) -> Bool {
        let needle = "localhost:\(Self.port)"
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let field = app.textFields["localhost.address"]
            if field.exists, ((field.value as? String) ?? "").contains(needle) { return true }
            if app.staticTexts[needle].exists { return true }
            usleep(300_000)
        } while Date() < deadline
        return false
    }

    /// Scroll until an element is genuinely on screen. `exists` and `isHittable`
    /// disagree at exactly the moment a row is under the floating tab bar, which
    /// is where the last row on this screen tends to sit.
    private func reveal(_ element: XCUIElement) {
        for _ in 0 ..< 4 where !element.isHittable {
            app.swipeUp()
            usleep(400_000)
        }
    }

    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }

    /// A frame, attached to the result bundle and written where a person can
    /// open it. The attachment is the tidy answer; the file is the one somebody
    /// actually looks at.
    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
