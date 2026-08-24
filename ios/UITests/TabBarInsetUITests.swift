/**
 * **Nothing a tab keeps may be drawn under the pill it keeps.**
 *
 * Asad, on 0.10.1, from his own phone: the About row on Settings read
 * *"Terminal Deck    0.10.1"* with the words **behind** the floating tab bar —
 * the pill drawn over them. Every long screen under the bar loses its last rows
 * the same way, and the loss is invisible in a code review because the content
 * is *there*, correctly laid out, with sixty points of translucent chrome on top
 * of it.
 *
 * ## Why this is a screen test and not a unit test
 *
 * Because the number is the system's. `DeckChromeTests` can hold the *rule* —
 * every surface that keeps the bar reserves room for it — but the bar's height
 * is decided by iOS, changes with the release, and on iOS 26 is a floating pill
 * that sits above the safe-area edge rather than on it. The only honest question
 * is the one asked here: on a real screen, scrolled to its end, does the last
 * thing on it sit clear of the bar that is actually drawn?
 *
 * Both halves are asserted, and they fail for different reasons:
 *
 *  - **Clear of the bar.** The bottom of the last row is above the top of the
 *    pill. This is the complaint.
 *  - **Not absurdly clear of it.** A screen that reserves three hundred points
 *    is not fixed, it is over-corrected, and a one-sided assertion would call
 *    that a pass forever. The ceiling is generous — this is not the place to pin
 *    a number to the point — but it is finite.
 *
 * ## Pairing itself
 *
 * The same arrangement `TerminalBottomInsetUITests` uses, and the same standing
 * rule for this target: skip rather than fail when there is no harness, because
 * a suite that goes red on a laptop with nothing running is a suite that gets
 * deleted in a week.
 *
 *     ios/Harness/run.sh host --approve-after 3000 &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/TabBarInsetUITests
 */

import XCTest

final class TabBarInsetUITests: XCTestCase {

    private var app: XCUIApplication!
    private static var reachable: Bool?

    /// The harness's control server. `run.sh host` puts it at the relay's port
    /// plus one; the env var is how a run on a machine where 8787 is already
    /// taken — several worktrees on one Mac — says where it actually is.
    private static let control: URL = {
        let named = ProcessInfo.processInfo.environment["TD_CONTROL"] ?? ""
        if !named.isEmpty {
            let text = named.hasPrefix("http") ? named : "http://\(named)"
            if let url = URL(string: text) { return url }
        }
        return URL(string: "http://127.0.0.1:8788")!
    }()
    private static let notRunning =
        "No harness. Start ios/Harness/run.sh host --approve-after 3000 and run again."

    /// The most a screen may reserve before the reservation is itself the
    /// defect. The pill is about fifty points tall and floats about twenty above
    /// the safe-area edge; anything past this is a band of nothing.
    private static let mostReasonableClearance: CGFloat = 140

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()
        try pairIfNeeded()

        let arrived = app.tabBars.firstMatch.waitForExistence(timeout: Self.reachable == nil ? 60 : 20)
        Self.reachable = arrived
        try XCTSkipUnless(arrived, Self.notRunning)
    }

    /**
     * Get this phone onto a machine, through whichever door is in front of it.
     *
     * Two doors, because the gate is the **login** now: a phone with nothing at
     * all lands on `ServerLoginView`, where pairing is the line underneath, and
     * a phone that already has a server is past the gate with an empty machine
     * list and reaches the same sheet from Machines. Both end at
     * `pairing.field`, and the screens this suite measures are only worth
     * measuring with a machine behind them — Devices, "This server" and the host
     * version are the rows that pushed his About row under the pill.
     */
    private func pairIfNeeded() throws {
        // **Connected**, not merely *listed*. A phone that is paired to a host
        // which is no longer answering looks identical on the Machines row and
        // draws none of the screens this suite is here to measure — no Devices,
        // no "This server", no host version — so the rows that pushed his About
        // row under the pill would all be missing and the run would prove
        // nothing while passing.
        if app.tabBars.firstMatch.waitForExistence(timeout: 10), isConnected(within: 20) { return }

        if app.buttons["serverLogin.pairingDoor"].waitForExistence(timeout: 25) {
            app.buttons["serverLogin.pairingDoor"].tap()
        } else if app.openMachinesTab() {
            app.buttons["machines.add"].tap()
        }

        let field = app.textFields["pairing.field"]
        guard field.waitForExistence(timeout: 20) else {
            save("inset-00-no-pairing-screen")
            return
        }
        // A digit at a time, checked. The field formats as it fills and a single
        // `typeText` of six characters lost one of them on this simulator — five
        // digits and a refusal that reads exactly like a wrong code.
        let code = try pairingCode()
        field.tap()
        for digit in code {
            field.typeText(String(digit))
            usleep(120_000)
        }
        for _ in 0 ..< 4 {
            guard field.exists else { break }
            let typed = (field.value as? String ?? "").filter { $0.isNumber }
            if typed.count >= code.count { break }
            for digit in code.dropFirst(typed.count) where field.exists {
                field.typeText(String(digit))
                usleep(150_000)
            }
        }
        save("inset-00-code-typed")
        // Checked again immediately before the tap. The field submits itself on
        // the sixth digit, so between `exists` and `tap` the button can be gone —
        // which XCUITest reports as a failure to tap rather than as the pairing
        // having already started.
        let submit = app.buttons["pairing.submit"]
        if submit.exists, submit.isHittable { submit.tap() }
        // The harness approves after three seconds; the phone then reconnects and
        // the machine's rows appear. Nothing here taps during that window.
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 60)
        _ = isConnected(within: 90)
        save("inset-00-after-pairing")
    }

    /// Whether the machine on screen is answering, read off the connection pill
    /// rather than inferred from the machine list.
    private func isConnected(within seconds: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if pill.exists, pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }

    // MARK: - The screens

    /// Settings, which is the screen he photographed: the last thing on it is
    /// the paragraph under About, and the row above it is the one whose name was
    /// behind the pill.
    func testSettingsClearsTheBar() throws {
        app.openTab("Settings")
        let scrolled = scrollToTheEnd()
        save("inset-settings")
        try assertClear("settings.noPushNote", on: "Settings", scrolled: scrolled)
        // The row he photographed. Only the floor here: it is not the last thing
        // on the screen, so how far above the bar it sits is the paragraph's
        // business rather than the inset's.
        try assertClear("settings.version", on: "Settings", mustBeVisible: false, scrolled: false)
    }

    /// The session list. A `List` rather than a `ScrollView`, which is exactly
    /// why it is asked as well: the two containers inset themselves differently
    /// and a rule that only reached one of them would leave half the app wrong.
    func testTheSessionListClearsTheBar() throws {
        app.openTab("Sessions")
        _ = scrollToTheEnd()
        save("inset-sessions")
        try assertLastRowClear(matching: "session.", on: "Sessions")
    }

    /// The Localhost tab, whose footnote is its last row.
    func testLocalhostClearsTheBar() throws {
        app.openTab("Localhost")
        let scrolled = scrollToTheEnd()
        save("inset-localhost")
        // A machine with no ports draws the empty state instead of the footnote,
        // and the empty state is what has to clear the bar there.
        let last = app.descendants(matching: .any).matching(identifier: "localhost.footnote").firstMatch.exists
            ? "localhost.footnote"
            : "localhost.empty"
        try assertClear(last, on: "Localhost", scrolled: scrolled)
    }

    /// Machines, pushed from Settings — *"pill should be on here only on the
    /// homepage or machines or settings"*, so it keeps the bar and owes it room.
    func testMachinesClearsTheBar() throws {
        XCTAssertTrue(app.openMachinesTab(), "Machines should be reachable from Settings")
        _ = scrollToTheEnd()
        save("inset-machines")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "Machines keeps the bar")
        try assertLastRowClear(matching: "machines.", on: "Machines")
    }

    /**
     * The device roster, pushed from Settings — the second screen in his
     * recording, and one whose scrolling content ends in a paragraph the same
     * way Settings does.
     *
     * Photographed as well as measured: this is the list that showed his phone
     * twice, and the host-side rule that stops it is asserted in
     * `src/main/remote/device-auth.test.ts`. What a frame adds is that the row
     * is *readable* — name, standing, when it was last here, and the fingerprint
     * a person is being asked to compare.
     */
    func testTheDeviceRosterClearsTheBar() throws {
        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable")
        let row = app.buttons["settings.devices"]
        try XCTSkipUnless(row.waitForExistence(timeout: 15),
                          "this host does not serve the device roster")
        row.tap()
        // The roster is asked for on appear and drawn when it lands.
        _ = app.staticTexts["Devices"].waitForExistence(timeout: 15)
        sleep(3)
        let scrolled = scrollToTheEnd()
        save("inset-devices")
        try assertClear("devices.footnote", on: "Devices", mustBeVisible: false, scrolled: scrolled)
    }

    // MARK: - Measuring

    /// The frame of the bar that is actually drawn, in window coordinates.
    private func barFrame() throws -> CGRect {
        let bar = app.tabBars.firstMatch
        guard bar.exists else { throw XCTSkip("no tab bar on this screen") }
        return bar.frame
    }

    /**
     * The measurement.
     *
     * `scrolled` is what decides whether the **ceiling** is asked at all, and it
     * has to: on a screen whose content is shorter than the phone, the distance
     * from the last row to the bar is the empty half of the screen and says
     * nothing about any inset. Asking the ceiling there fails a screen for being
     * short. The floor is asked either way — content under the bar is wrong
     * whether or not the screen scrolls.
     */
    private func assertClear(_ identifier: String,
                             on screen: String,
                             mustBeVisible: Bool = true,
                             scrolled: Bool) throws {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.exists else {
            if mustBeVisible { XCTFail("\(screen): \(identifier) is not on screen at all") }
            return
        }
        let bar = try barFrame()
        let gap = bar.minY - element.frame.maxY
        report("\(screen) — \(identifier) \(element.frame)  bar \(bar)  gap \(gap)  scrolled \(scrolled)")
        XCTAssertGreaterThanOrEqual(
            gap, 0,
            "\(screen): the bottom of \(identifier) is \(-gap) points *under* the tab bar — "
            + "this is the About row reading “Terminal Deck 0.10.1” with the pill drawn over it")
        guard scrolled else { return }
        XCTAssertLessThan(
            gap, Self.mostReasonableClearance,
            "\(screen): \(identifier) stops \(gap) points short of the bar at the end of a "
            + "screen that scrolls — that is a band of nothing, not an inset")
    }

    private func assertLastRowClear(matching prefix: String, on screen: String) throws {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        guard rows.count > 0 else { throw XCTSkip("\(screen) has no rows to measure") }
        let bar = try barFrame()
        var lowest = CGRect.null
        for index in 0 ..< rows.count {
            let frame = rows.element(boundBy: index).frame
            if lowest.isNull || frame.maxY > lowest.maxY { lowest = frame }
        }
        let gap = bar.minY - lowest.maxY
        report("\(screen) — lowest row \(lowest)  bar \(bar)  gap \(gap)")
        XCTAssertGreaterThanOrEqual(
            gap, 0,
            "\(screen): its last row is \(-gap) points under the tab bar")
    }

    /// Swipe to the end, and answer **whether the screen moved at all** — which
    /// is the difference between "this is where the content stops" and "this is
    /// where the screen stops", and the two want different assertions.
    @discardableResult
    private func scrollToTheEnd() -> Bool {
        let probe = app.descendants(matching: .any).element(boundBy: 0)
        var moved = false
        var before = anchorY()
        for _ in 0 ..< 6 {
            app.swipeUp()
            let after = anchorY()
            if let before, let after, abs(after - before) > 1 { moved = true }
            before = after
        }
        _ = probe
        sleep(1)
        return moved
    }

    /// Something on screen whose position answers *did this move*.
    ///
    /// The **last** static text rather than the first: the first is usually the
    /// navigation title, which is pinned and reports "nothing moved" for a screen
    /// that scrolled perfectly well.
    private func anchorY() -> CGFloat? {
        let texts = app.descendants(matching: .staticText)
        let count = texts.count
        guard count > 0 else { return nil }
        return texts.element(boundBy: count - 1).frame.minY
    }

    // MARK: - Plumbing

    private func pairingCode() throws -> String {
        guard let data = try? Data(contentsOf: Self.control.appendingPathComponent("pair")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else {
            Self.reachable = false
            throw XCTSkip(Self.notRunning)
        }
        return code
    }

    private func report(_ measurement: String) {
        add(XCTAttachment(string: measurement))
        print("[tab-bar-inset] \(measurement)")
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots = ProcessInfo.processInfo.environment["TD_SHOTS"], !shots.isEmpty {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }
}
