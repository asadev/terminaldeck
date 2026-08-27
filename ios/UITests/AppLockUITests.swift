/**
 * The app lock, tapped rather than asserted about.
 *
 * `AppLockTests` walks every branch of the state machine against a made-up clock
 * and a made-up sensor, which is the right way to test a five-minute rule and
 * the wrong way to find out whether the switch is on the screen, whether the
 * lock screen is above the sheets, and whether the Secure Enclave answers the
 * policy this app actually asks for. This suite is the finger.
 *
 * ## Running it
 *
 *     ios/Harness/run.sh host --port 8891 \
 *         --rendezvous wss://relay.terminaldeck.dev --approve-after 4000
 *
 *     TEST_RUNNER_TD_CONTROL=127.0.0.1:8892 \
 *     TEST_RUNNER_TD_SHOTS=/private/tmp/applock-shots \
 *     xcodebuild test -only-testing:TerminalDeckUITests/AppLockUITests …
 *
 * The `--rendezvous` flag is not optional and the reason is written up in
 * `host-standin.ts`: the phone has no relay setting, so a pairing code minted at
 * a local relay is looked up somewhere the host is not sitting. What goes onto
 * the public relay is a slot holding an offer whose address is `127.0.0.1`.
 *
 * ## The Face ID sheet, and who presses it
 *
 * Nothing in this process can. `xcrun simctl ui <device> biometric match` is a
 * command on the **Mac**, so the shape of every case here is: do the thing that
 * raises the prompt, then wait quietly while a sender on the other side of the
 * simulator boundary answers it.
 *
 * "Quietly" is load-bearing. XCUITest dismisses an unexpected interrupting
 * element by *tapping* it, and the element on screen while this waits is the
 * system's own Face ID sheet with a Cancel button on it. So the wait is a sleep
 * rather than a `waitForExistence` — a query is what arms the interruption
 * monitor, and arming it here would have the test press Cancel on the prompt it
 * is waiting for.
 */

import XCTest

final class AppLockUITests: XCTestCase {

    private var app: XCUIApplication!

    private static let noStandIn =
        "No stand-in. Start ios/Harness/run.sh host --port 8891 "
        + "--rendezvous wss://relay.terminaldeck.dev --approve-after 4000 and pass "
        + "TEST_RUNNER_TD_CONTROL=127.0.0.1:8892."

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var control: String { env("TD_CONTROL") }
    private var shots: String { env("TD_SHOTS") }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - On

    /**
     * The switch is on the main Settings page, it is off, and moving it asks for
     * a face before it turns anything on.
     */
    func testTheSwitchIsOnTheMainSettingsPageAndTurnsTheLockOn() throws {
        try XCTSkipIf(control.isEmpty, Self.noStandIn)
        app.launch()
        try arrive()

        XCTAssertTrue(openSettings(), "never reached Settings")
        let row = app.staticTexts["settings.appLockLabel"].firstMatch
        reveal(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the lock switch has to be on the main Settings page")
        // The name on screen is the name this device's sensor actually has.
        XCTAssertTrue(row.label.hasPrefix("Lock the app with"), row.label)
        XCTAssertTrue(app.staticTexts["settings.appLockRule"].firstMatch.exists,
                      "the screen has to say when it will ask")
        shoot("01-settings-switch-off")

        let toggle = app.switches["settings.appLock"].firstMatch
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(toggle.value as? String, "0", "the lock ships off")
        toggle.tap()

        // The prompt is up. Say nothing to it; the Mac answers.
        answerTheSheet()

        XCTAssertEqual(app.switches["settings.appLock"].firstMatch.value as? String, "1",
                       "a matched face should have turned the lock on")
        shoot("02-settings-switch-on")
    }

    // MARK: - Off

    /**
     * Turning it **off** asks too, and that is the whole protection: a phone
     * handed over unlocked for thirty seconds must not be a phone whose lock can
     * be switched off by whoever is holding it.
     *
     * Run after the case above, against an app that is already locked — so this
     * also photographs a cold start walking all the way through to Settings.
     */
    func testTurningItOffAsksForAFaceFirst() throws {
        try XCTSkipIf(control.isEmpty, Self.noStandIn)

        // The answer is queued **before** the launch, because the prompt is up
        // within a second of the process starting and nothing in this test may
        // ask XCUITest a question while it is — see `answerTheSheet`.
        request("match")
        app.launch()
        sleep(4)
        // A photograph rather than a query: `XCUIScreen.screenshot()` reads the
        // screen without going through an element query, so it does not arm the
        // interruption monitor over the biometric sheet.
        shoot("08-cold-start-locked")
        sleep(10)

        XCTAssertTrue(openSettings(), "never reached Settings after unlocking")
        let toggle = app.switches["settings.appLock"].firstMatch
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, "1", "the lock should still be on")
        toggle.tap()
        answerTheSheet()

        XCTAssertEqual(app.switches["settings.appLock"].firstMatch.value as? String, "0",
                       "a matched face should have turned the lock off")
        shoot("09-settings-switch-off-again")
    }

    // MARK: - Getting there

    /**
     * The Settings tab, `firstMatch` all the way down.
     *
     * `XCUIApplication.openSettingsTab()` is the shared helper and it is right
     * for every other suite; here it throws *"Multiple matching elements found"*
     * on the tab-bar button. This app is drawing two tab bars in the frame after
     * an unlock — the floating pill iOS 26 renders and the one behind it — and
     * for the purposes of this suite either will do. The shared helper is left
     * strict on purpose: six suites use it and a silent `firstMatch` there would
     * hide a real duplicate one day.
     */
    @discardableResult
    private func openSettings() -> Bool {
        // The **hittable** one, not the first one. With the lock window in the
        // scene there are two matches for this button and only one of them is on
        // screen; `firstMatch` picks by tree order, and a tap on the other lands
        // nowhere at all — silently, which is the worst way for it to fail.
        let matches = app.tabBars.buttons.matching(identifier: "Settings")
        var tapped = false
        for index in 0 ..< max(matches.count, 1) {
            let candidate = matches.element(boundBy: index)
            guard candidate.exists, candidate.isHittable else { continue }
            candidate.tap()
            tapped = true
            break
        }
        if !tapped {
            let anywhere = app.buttons.matching(identifier: "Settings")
            for index in 0 ..< max(anywhere.count, 1) {
                let candidate = anywhere.element(boundBy: index)
                guard candidate.exists, candidate.isHittable else { continue }
                candidate.tap()
                tapped = true
                break
            }
        }
        if app.buttons["settings.alerts"].firstMatch.waitForExistence(timeout: 8) { return true }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
        if app.buttons["settings.alerts"].firstMatch.waitForExistence(timeout: 10) { return true }
        shoot("zz-could-not-reach-settings")
        return false
    }

    /// Past the gate, by typing six digits at the stand-in.
    private func arrive() throws {
        if app.tabBars.firstMatch.waitForExistence(timeout: 6) { return }
        let door = app.buttons["serverLogin.pairingDoor"]
        if door.waitForExistence(timeout: 10) { door.tap() }
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no pairing field to type into")
        field.tap()
        field.typeText(try freshCode())
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 120),
                      "the machine never approved this device")
    }

    private func freshCode() throws -> String {
        guard let url = URL(string: "http://\(control)/pair"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw XCTSkip(Self.noStandIn)
        }
        let digits = text.filter(\.isNumber)
        guard digits.count >= 6 else { throw XCTSkip("\(control) answered \(text)") }
        return String(digits.suffix(6))
    }

    /**
     * Ask the Mac to answer the biometric sheet, and wait quietly while it does.
     *
     * The request is a file, because that is the only channel across the
     * simulator boundary this process has: nothing in here can run
     * `osascript`, and `simctl` has no biometric subcommand on Xcode 26.6 at
     * all — the Simulator's own **Features ▸ Face ID ▸ Matching Face** menu is
     * what moves the sensor, and that menu is on the Mac.
     *
     * The wait is a `sleep` and not a `waitForExistence`, which is the detail
     * that took a run to learn: a query is what arms XCUITest's interruption
     * monitor, the interrupting element while this waits is the system's own
     * Face ID sheet, and the monitor dismisses an interruption by **tapping**
     * it — straight onto Cancel.
     */
    private func answerTheSheet(_ answer: String = "match") {
        request(answer)
        sleep(14)
    }

    /// Queue the answer without waiting for it — for the case where the prompt
    /// arrives before there is anything to wait on, which is every cold start.
    private func request(_ answer: String) {
        guard !shots.isEmpty else { return }
        let file = URL(fileURLWithPath: shots).appendingPathComponent("face.request")
        try? answer.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Scroll until an element is genuinely on screen. `exists` and `isHittable`
    /// disagree exactly where a row sits under the floating tab bar.
    private func reveal(_ element: XCUIElement) {
        for _ in 0 ..< 5 where !element.isHittable {
            app.swipeUp()
            usleep(400_000)
        }
    }

    private func shoot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !shots.isEmpty else { return }
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: shots)
            .appendingPathComponent("\(name).png"))
    }
}
