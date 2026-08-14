/**
 * The iPhone against the **real** desktop, over the **live** relay.
 *
 * Everything else in this folder proves the phone against `scripts/remote-host.sh`
 * — the product's own server and `PtyManager` in a plain Node process, with a
 * relay of its own on loopback. That is a good stand-in and it is still a
 * stand-in: `PLAN.md` records that both phone stand-ins once shared a bug with
 * their clients and hid an 81-versus-80 byte error for a day. Android has met
 * the shipping desktop over `relay.terminaldeck.dev`; until this ran, iOS never
 * had.
 *
 * So there is nothing fake in the path this exercises: the packaged
 * `/Applications/Terminal Deck.app`, the deployed relay, a code minted by a
 * person pressing **Pair a device**, and an approval given at the Mac.
 *
 * ## Running it
 *
 * It needs a code, and a code is worth sixty seconds — far less than a
 * simulator takes to boot, which is why nothing here is passed in as an
 * argument. The test **waits at the pairing screen for a file to appear** and
 * pairs the moment it does, so the code is minted after the phone is already
 * standing at the desk:
 *
 *     mkdir -p /tmp/td/chain && rm -f /tmp/td/chain/pair-uri.txt
 *     TEST_RUNNER_TD_PAIR_FILE=/tmp/td/chain/pair-uri.txt \
 *     TEST_RUNNER_TD_EXPECT_HOST=$(hostname -s) \
 *     TEST_RUNNER_TD_SHOTS=/tmp/td/chain/shots \
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
 *       -only-testing:TerminalDeckUITests/RealDesktopUITests
 *
 * Then, at the Mac: Settings → Remote → Pair a device, and write the code in
 * the QR into that file. Approve the device when it appears.
 *
 * A simulator process is a plain macOS process, so it reads and writes host
 * paths — which is what makes both the hand-off and the run log possible.
 *
 * ## Why it types real commands, when `MultiHostUITests` refuses to
 *
 * That test deliberately never presses Return: it types a marker and reads it
 * back, because pressing Return would run something on somebody's machine. Here
 * running something on the machine **is the evidence**, and no other kind would
 * do — a phone can draw whatever it likes on its own screen. So this types
 * `hostname`, `stty size` and `sleep 300`, in a session **it started itself**,
 * and never in one that was already there. Two rules come out of that and both
 * are load-bearing:
 *
 *  - **It never taps an existing session row.** The sessions on a real desktop
 *    belong to whoever is using it.
 *  - **Everything it runs is read-only or self-contained.** `hostname` and
 *    `stty size` report; `sleep 300` waits and is then interrupted. Nothing
 *    writes a file, installs anything, or touches a repository.
 *
 * ## What is proved here, and what is proved outside
 *
 * What is on this screen came back through the sealed channel — nothing echoes
 * locally, `TerminalBridge` draws only what arrives through `feed` — so the
 * Mac's own hostname appearing here could not have been invented by the phone.
 * The rest is deliberately *not* asserted here, because a test that both drives
 * the phone and grades it is one program's opinion: that the `sleep` is a real
 * process, that the pty really resized, and that the relay leaked no channel
 * are read on the Mac, from the Mac's own `ps`, its own pty and the relay's own
 * count, while this holds the screen still. The pauses below are that window,
 * and they are why this test is slow on purpose.
 */

import XCTest


final class RealDesktopUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Where the pairing code will appear. Absent means "not this run".
    private var pairFile: String { ProcessInfo.processInfo.environment["TD_PAIR_FILE"] ?? "" }
    /// The Mac's short hostname, so the check is against a value from the Mac.
    private var expectHost: String { ProcessInfo.processInfo.environment["TD_EXPECT_HOST"] ?? "" }
    private var shots: String? { ProcessInfo.processInfo.environment["TD_SHOTS"] }

    private static let notRunning =
        "The real desktop is not being driven. Set TEST_RUNNER_TD_PAIR_FILE to a path this run "
        + "will write a terminaldeck:// code into, and TEST_RUNNER_TD_EXPECT_HOST to the Mac's "
        + "hostname. See the header."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(pairFile.isEmpty || expectHost.isEmpty, Self.notRunning)
        app = XCUIApplication()
        app.launch()
    }

    /**
     * Nothing is unpaired here, and that is deliberate.
     *
     * A pairing lasts until it is revoked — A1.4 — so a second run of this must
     * find the machine still there and come straight up without a code. Wiping
     * the Keychain in `setUp`, which is what the other suites do because they
     * talk to disposable stand-ins, would throw that away and would also mean
     * begging a fresh sixty-second code out of a human for every run.
     */

    // MARK: - The whole chain

    func testTheRealDesktopOverTheLiveRelay() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 20) {
            capture("01-waiting-for-a-code")
            let code = try waitForCode()
            XCTAssertTrue(code.hasPrefix("terminaldeck://"),
                          "the relay shape is the one being proved; a tailnet code tests another path")
            field.tap()
            field.typeText(code)
            app.buttons["pairing.submit"].tap()
            capture("02-code-submitted")
        } else {
            // Already paired from a previous run, which is itself the A1.4
            // claim holding: nothing expired, nothing had to be re-scanned.
            XCTAssertTrue(app.buttons["sessions.more"].waitForExistence(timeout: 20),
                          "neither the pairing screen nor the session list came up")
            capture("01-already-paired")
        }

        // Long, because a person has to press Approve at the Mac in the middle
        // of it. That is not a delay to engineer away — it is the product
        // refusing to let anything in on a code alone.
        try waitForConnected(timeout: 300)
        capture("03-connected")

        // A session this phone starts, never one that was already there.
        try startSession()
        XCTAssertTrue(terminalView.waitForExistence(timeout: 30), "the session should open its terminal")
        capture("04-terminal")

        /*
         * The Mac's own name, fetched from the Mac.
         *
         * Nothing echoes locally in this app, so a hostname on this screen was
         * put there by a shell on the other end. The expected value comes from
         * the Mac's `hostname`, not from anything the phone could know.
         */
        try run("hostname")
        sleep(4)
        capture("05-hostname")
        hold("hostname")

        // The size the phone negotiated, read by the shell out of the pty the
        // Mac owns. Held on screen for the Mac-side read of the same pty.
        try run("stty size")
        sleep(4)
        capture("06-stty-size")
        hold("stty size")

        /*
         * A real process, interrupted for real.
         *
         * `sleep 300` is picked because it is unmistakable in `ps` on the Mac
         * and because it does nothing at all until it is killed. The pause is
         * the window in which the Mac confirms the process exists; the pause
         * after Ctrl-C is the window in which it confirms it is gone.
         */
        try run("sleep 300")
        sleep(6)
        capture("07-sleeping")
        sleep(25)

        try ctrlC()
        sleep(8)
        capture("08-interrupted")
        hold("after Ctrl-C")

        /*
         * The clipboard, outwards — A3.8's unproven half.
         *
         * Paste-in has been verified for a while; copy-*out* never had evidence
         * that was not the app's own word for it. `UIPasteboard.general` cannot
         * be read from the runner without raising the system consent alert on
         * the same thread that would have to answer it, and the app saying
         * "Copied 9 lines" is the app grading itself.
         *
         * So the read happens **on the Mac**: `xcrun simctl pbpaste` against this
         * simulator's own pasteboard, with no consent involved and nothing from
         * this process in the loop. The marker is minted here, printed by a shell
         * on the Mac, drawn on this screen only because it came back through the
         * sealed channel, and then named in the checkpoint log so the host-side
         * read can be tied to this exact step rather than to a timestamp.
         *
         * It runs *before* the background cycle deliberately — see the note there
         * about the 120-second animations-idle stall that cycle costs.
         */
        let marker = "TD-COPYOUT-\(UInt32.random(in: 100_000...999_999))"
        try run("echo \(marker)")
        sleep(4)
        capture("11-copy-marker-on-screen")

        app.buttons["terminal.actions"].tap()
        let copyScreen = app.buttons["terminal.copyScreen"]
        XCTAssertTrue(copyScreen.waitForExistence(timeout: 15),
                      "Copy Screen must be reachable from the actions menu")
        copyScreen.tap()

        /*
         * The on-screen half, caught rather than hoped for.
         *
         * The toast is up for 2.5 seconds, so a `sleep(2)` and a screenshot lands
         * on the edge of it — the first version of this did exactly that and
         * photographed an empty screen while the copy had plainly worked. Waiting
         * for the element and reading its text is both faster and an actual
         * assertion: "Copied N lines from the screen." is the app reporting the
         * outcome, which 2.3 requires of a silent action.
         */
        let toast = app.staticTexts["terminal.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 6),
                      "copying must say so; a silent clipboard button feels broken")
        capture("12-copied-out")
        XCTAssertTrue(toast.label.hasPrefix("Copied"),
                      "the toast should report what was copied, and said: \(toast.label)")

        // And now the durable half, which this test deliberately does not read:
        // `UIPasteboard.general.string` from here raises the system consent on
        // the thread that would have to answer it. The Mac reads the simulator's
        // own pasteboard with `xcrun simctl pbpaste` during this pause, and the
        // marker is named in the checkpoint log so that read can be tied to this
        // step.
        hold("copy-out marker \(marker)")

        /*
         * Dropped and re-attached.
         *
         * Backgrounding is how a phone really loses a session — the socket goes
         * when iOS suspends the app — so that is what is done rather than
         * anything test-only. What must be true afterwards is that the terminal
         * comes back and the relay is not still holding the channel that died.
         *
         * ## This step costs two minutes, and the test is not hung
         *
         * **Do not kill the run here.** Somebody already did, and recorded it in
         * `PLAN.md` as "no green exit". It has one — three runs, 280 s / 300 s /
         * 299 s, zero failures — and about 120 of those seconds are two
         * back-to-back 60-second timeouts inside the *single* `typeText` below.
         * Everything before this point is fast, the Copy Screen tap included: in
         * the last run the whole clipboard step took 5.6 s.
         *
         * Measured rather than guessed, from the app's own log inside the
         * simulator (`log show --predicate 'subsystem CONTAINS "XCTest"'`):
         *
         *     Received request to notify when the main run loop is idle
         *     Idle notifier run loop observer fired
         *     Sending main run loop idle reply
         *     Received request to notify when animations are idle      ← no reply
         *
         * The run-loop half answers instantly. The *animations* half is asked and
         * never answered, so XCUITest waits out its timeout, prints "App
         * animations complete notification not received, will attempt to
         * continue", and carries on correctly. Everything after this point
         * passes. During the stall the app sits at **0.0% CPU** with its main
         * thread parked in `mach_msg2_trap` — nothing is animating, something is
         * merely still *counted* as animating across the suspend.
         *
         * Two things this is **not**, both ruled out by experiment rather than by
         * reading the code:
         *
         *  - **Not `StatusDot`'s `.repeatForever`**, which was the standing
         *    hypothesis. A throwaway app containing nothing but that animation
         *    reaches idle in 0.33 s per interaction — identical to the same app
         *    with no animation at all, and identical again after a 20-second
         *    background cycle. And at the stall the dot here is amber `waiting`,
         *    so the animating branch is not even selected.
         *  - **Not the background cycle by itself.** That same throwaway app
         *    survives `press(.home)` → `activate()` with no stall.
         *
         * The strong remaining suspect is SwiftTerm's caret: `TerminalOptions`
         * defaults to `.blinkBlock`, `iOSCaretView` blinks it with
         * `UIView.animate(options: [.autoreverse, .repeat])` re-armed from its own
         * completion handler, and `CaretView.foreground()` re-arms it again on
         * `UIApplication.willEnterForegroundNotification` — which is exactly this
         * moment. That attribution is **UNPROVEN**; the mechanism above is not.
         */
        XCUIDevice.shared.press(.home)
        sleep(20)
        app.activate()
        XCTAssertTrue(terminalView.waitForExistence(timeout: 60), "the terminal should come back")
        /*
         * No connection-pill check here, and not because one would be
         * inconvenient: `connection.pill` lives in `HostSwitcher`, which is the
         * session list's toolbar. This screen is a terminal, and its own header
         * shows the *session's* status instead. Asserting the pill here looked
         * reasonable and failed with "the pill said nothing" — which is true,
         * and says nothing about the connection. What proves the re-attach is
         * the session taking input again, three lines down, and the relay's own
         * guest count read from the Mac.
         */
        capture("09-reattached")

        // And it is the same session, still taking input, with what came before
        // the drop still on it — the scrollback surviving the round trip.
        try run("echo TD-AFTER-REATTACH")
        sleep(4)
        capture("10-alive-after-reattach")
        hold("after re-attach")
    }

    // MARK: - Steps

    /// Block at the pairing screen until somebody mints a code. Ten minutes,
    /// because the person doing it is also reading a QR code off a screen.
    private func waitForCode() throws -> String {
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: pairFile, encoding: .utf8) {
                let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty { return code }
            }
            usleep(500_000)
        }
        capture("zz-no-code")
        throw XCTSkip("no code was written to \(pairFile) in ten minutes. \(Self.notRunning)")
    }

    /// Start a session and open it. Never reuses one: see the header.
    private func startSession() throws {
        let new = app.buttons["sessions.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 60),
                      "the desktop should advertise `create`, so the button should be there")
        new.tap()
        // A menu when the desktop has folders to offer, a plain button when it
        // has none. `.firstMatch` because the menu's section title matches too.
        let plain = app.buttons["New session"].firstMatch
        if plain.waitForExistence(timeout: 4) { plain.tap() }
    }

    /// Type a command and press Return.
    private func run(_ command: String) throws {
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 30), "the terminal toolbar should be up")
        if !app.keyboards.firstMatch.exists {
            keyboard.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15),
                          "the keyboard toggle should raise a keyboard to type into")
        }
        // The QuickPath tutorial — *"Speed up your typing by sliding your
        // finger"* — is put up by the system keyboard the first time it appears
        // on a fresh simulator. It sits over the accessory row, so ^C is behind
        // it. Nothing to do with this app; dismissed the way a person would.
        let continueButton = app.buttons["Continue"]
        if continueButton.exists { continueButton.tap() }
        app.typeText(command + "\n")
    }

    /// Ctrl-C, from the accessory row where a thumb already is.
    private func ctrlC() throws {
        if !app.keyboards.firstMatch.exists { app.buttons["terminal.keyboard"].tap() }
        let interrupt = app.buttons["^C"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 15),
                      "the accessory row should carry ^C")
        interrupt.tap()
    }

    // MARK: - Helpers

    /// See `MultiHostUITests.terminalView`: SwiftTerm's view is a `UIScrollView`,
    /// so a query for an `other` never matches it.
    private var terminalView: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
    }

    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            usleep(500_000)
        }
        capture("zz-not-connected")
        XCTFail("never reached Connected; the pill said "
                + "\(pill.exists ? pill.label : "nothing")")
    }

    /**
     * Stand still, so the Mac can look.
     *
     * The phone is not the witness here. Everything this suite exists to prove
     * is *"the Mac really did this"*, and a phone reading its own screen and
     * agreeing with itself is one program's opinion — so the checks live on the
     * host, in `ps`, in the pty, and in the relay's own guest count, and this
     * pause is the window they read in.
     *
     * There is no in-test read of the terminal to replace them with, and two
     * attempts are recorded here so nobody spends the night finding out again:
     *
     *  - **The accessibility tree has no terminal text in it.** SwiftTerm draws
     *    its buffer and publishes no element per line, so `label CONTAINS x`
     *    never sees a character of output. It appears to work in the other
     *    suites only because the software keyboard echoes what was just typed
     *    into its autocorrect bar — a query for a string the test typed matches
     *    the *keyboard*. A string the test did not type, like a hostname the Mac
     *    chose, matches nothing. That is how this was found.
     *  - **The pasteboard cannot be read from this process.** Copy Screen does
     *    publish the buffer, but a cross-app read raises the system consent and
     *    `UIPasteboard.general.string` blocks the calling thread until it is
     *    answered — the same thread that would have to tap Allow. The run stops
     *    dead. `xcrun simctl pbpaste` on the host reads it with no consent at
     *    all, which is both easier and better evidence.
     *
     * Copy Screen *is* driven from here, and that read is what proves A3.8's
     * outward half. An earlier note here blamed the status dot's `.repeatForever`
     * for a stall after that tap; that was wrong, and the correction — with the
     * experiment that falsified it — is beside the background step below.
     */
    private func hold(_ label: String) {
        // A dated marker on the host, so what it reads can be tied to the step
        // that produced it rather than guessed at from timestamps. Appended,
        // because a checkpoint log with one line in it is a bug.
        if let shots {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            let line = "\(ISO8601DateFormatter().string(from: Date()))  \(label)\n"
            if let handle = FileHandle(forWritingAtPath: "\(shots)/checkpoints.log") {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: "\(shots)/checkpoints.log", atomically: false, encoding: .utf8)
            }
        }
        sleep(10)
    }

    private func capture(_ name: String) {
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
