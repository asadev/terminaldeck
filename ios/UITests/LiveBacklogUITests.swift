/**
 * Opening a session does not scroll its history past you.
 *
 * ## The defect this exists to catch, in his words
 *
 *   > *"app mobile app is also doing the same thing: when we open a session it
 *   > really scrolls everything exactly same way and then it loads and all of
 *   > this stuff."*
 *
 * `TerminalBackfillTests` pins the policy — hide, buffer, feed once, reveal at
 * the bottom — with a fake clock and no UIKit at all, and it is the test that
 * will actually fail when somebody changes the rules. What it cannot see is
 * whether that policy is **attached to anything**: three lines in `HostLink` and
 * `TerminalBridge` decide whether a real replay goes through it, and a build
 * where those lines were dropped would keep every unit test green while the
 * phone went straight back to scrolling through the afternoon.
 *
 * So this one opens a real session with a real backlog on a real machine, and
 * looks at the glass.
 *
 * ## What is asserted, given that a terminal is one opaque element
 *
 * `TerminalScrollUITests` records the constraint: XCUITest cannot read the
 * terminal's text or ask SwiftTerm anything — the whole emulator is a single
 * accessibility element. What a test *can* do is measure the screenshot the
 * runner already takes, and the claim is about pixels anyway.
 *
 * The claim is **not** "the screen is blank for a moment". That was the first
 * version of this test and it was wrong: measured against a real host, four
 * thousand lines arrive and are written inside a quarter of a second, so the
 * hold had already released by the first sample and the assertion failed against
 * a build that was behaving perfectly. How long the hold lasts is a property of
 * somebody's network, not of this app.
 *
 * The claim is: **no frame after the tap is ever a partial scroll position.**
 * Every sample is either uniform — the surface still held at `alpha 0` — or
 * pixel-identical to where the session settles. That is exactly what "it does
 * not scroll everything past you" means, and it is what the old build could not
 * do: a watched replay paints line 400, then line 1200, then line 3000, each of
 * them a frame that is neither blank nor the final one.
 *
 * Sampled from half a second, after the navigation push has finished animating —
 * during a push the terminal is genuinely mid-slide and differs from its settled
 * self for reasons that have nothing to do with this feature. The old behaviour
 * is comfortably slower than that: sixty-odd `output` frames, each triggering a
 * redraw the compositor coalesces at the frame rate, is more than a second of
 * animated history, which is why it was visible enough to film.
 *
 * The band is the middle third of the frame: it excludes the navigation bar, the
 * key bar, and the bottom line where a blinking cursor would make two identical
 * screens compare unequal.
 *
 * A session with nothing in it would also pass every assertion here, which is
 * why the test **prints four thousand lines itself** before it looks.
 *
 * ## Running it
 *
 * Like every live suite here: it skips without `TD_READY_FILE`. The desktop half
 * is `scripts/remote-host.sh`, which runs the product's own remote endpoint, and
 * the six digits arrive through `TD_CODE_FILE` because a pairing code lives
 * sixty seconds and a Simulator takes longer than that to boot.
 */

import XCTest

final class LiveBacklogUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var readyFile: String { env("TD_READY_FILE") }
    private var codeFile: String { env("TD_CODE_FILE") }
    private var shots: String { env("TD_SHOTS") }

    /// How many lines are printed into the session before it is re-opened. Big
    /// enough that the replay arrives in many `output` frames — which is the
    /// thing being defended against — and small enough to print in a few seconds.
    private static let lines = 4000

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(readyFile.isEmpty,
                      "No live desktop. Start scripts/remote-host.sh and pass TD_READY_FILE.")
        app = XCUIApplication()
        app.launch()
        try connect()
    }

    func testOpeningASessionDoesNotScrollItsHistoryPast() throws {
        try fillASessionWithScrollback()

        // Back to the list, which is the path he filmed: leave the session, come
        // back to it, and watch it replay.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))

        let row = firstSessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the session should still be listed")
        row.tap()

        // From half a second — after the push animation — to three, which is
        // beyond the hold's own two-second ceiling.
        var samples: [(at: TimeInterval, shot: XCUIScreenshot)] = []
        var elapsed: TimeInterval = 0
        for at in [0.5, 0.9, 1.4, 2.2] {
            Thread.sleep(forTimeInterval: at - elapsed)
            elapsed = at
            samples.append((at, app.screenshot()))
        }
        Thread.sleep(forTimeInterval: 3.0 - elapsed)
        let settled = app.screenshot()
        capture(settled, "05-settled-3s")

        let end = band(of: settled)
        XCTAssertFalse(uniform(end),
                       "three seconds in the session should be on screen; a uniform frame here "
                       + "means the hold never released, which is worse than the bug it fixes")

        for (index, sample) in samples.enumerated() {
            let (at, shot) = sample
            capture(shot, String(format: "%02d-at-%.0fms", index + 1, at * 1000))
            let sampled = band(of: shot)
            XCTAssertTrue(uniform(sampled) || sampled == end,
                          "at \(at)s the terminal was showing something that is neither blank nor "
                          + "where the session settles — that is a partial scroll position, which "
                          + "is the whole of what he filmed")
        }
    }

    // MARK: - Getting there

    private func connect() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 25) {
            try? "pairing\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
            let code = waitForCode(at: codeFile, timeout: 240)
            XCTAssertEqual(code.count, 6, "the harness never wrote six digits to TD_CODE_FILE")
            field.tap()
            field.typeText(code)
        }
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(180)
        var lastNudge = Date.distantPast
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            if Date().timeIntervalSince(lastNudge) > 10 {
                lastNudge = Date()
                let tab = app.tabBars.firstMatch.buttons["Sessions"]
                if tab.exists { tab.tap() }
            }
            usleep(500_000)
        }
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    /// Start a session and print enough into it that a replay is many frames.
    private func fillASessionWithScrollback() throws {
        let tab = app.tabBars.firstMatch.buttons["Sessions"]
        if tab.exists { tab.tap() }

        let row = firstSessionRow()
        if row.waitForExistence(timeout: 10) {
            row.tap()
        } else {
            app.buttons["sessions.new"].tap()
            // A host offering folders draws a menu; one offering none starts a
            // session on the tap. `sessions.newDefault` is the menu's own
            // "New session" row — identified precisely because the toolbar
            // button carries the same words and a query on them matches both.
            let inMenu = app.buttons["sessions.newDefault"]
            if inMenu.waitForExistence(timeout: 5) { inMenu.tap() }
        }

        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        /*
         * A tap on the glass before a single keystroke.
         *
         * The terminal makes itself first responder when the screen appears,
         * which is enough for a person — but XCUITest synthesises keys against
         * the *focused element in the accessibility tree*, and without a touch
         * it finds none: "Neither element nor any descendant has keyboard
         * focus", which is how this test failed the first time it ran. A tap by
         * coordinate rather than by query, because the emulator is one opaque
         * element with no identifier to ask for.
         */
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .tap()
        Thread.sleep(forTimeInterval: 1)
        app.typeText("seq 1 \(Self.lines)\n")
        Thread.sleep(forTimeInterval: 8)
    }

    private func firstSessionRow() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'")).firstMatch
    }

    private func waitForCode(at path: String, timeout: TimeInterval) -> String {
        guard !path.isEmpty else { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        return ""
    }

    // MARK: - Looking

    /**
     * The middle third of a frame, sampled coarsely.
     *
     * That region is terminal on every phone this app supports, and it excludes
     * the navigation bar above, the key bar below, and the bottom line where a
     * blinking cursor would make two otherwise identical screens differ.
     *
     * The green channel alone: text here is grey on grey in both appearances, so
     * one channel carries the whole of the difference between glyphs and nothing.
     */
    private func band(of shot: XCUIScreenshot) -> [UInt8] {
        guard let cg = shot.image.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return [] }
        let perRow = cg.bytesPerRow
        let perPixel = cg.bitsPerPixel / 8
        let top = cg.height / 3
        var out: [UInt8] = []
        out.reserveCapacity((cg.height / 3 / 4) * (cg.width / 4))
        var y = top
        while y < top + cg.height / 3 {
            var x = 0
            while x < cg.width {
                out.append(bytes[y * perRow + x * perPixel + 1])
                x += 4
            }
            y += 4
        }
        return out
    }

    /**
     * Is this band one colour — nothing drawn?
     *
     * A tolerance rather than an equality: the Simulator renders at a scale
     * factor and the compositor is free to dither, so two samples inside a run
     * of background can differ by a point or two with nothing between them.
     */
    private func uniform(_ band: [UInt8]) -> Bool {
        guard let lowest = band.min(), let highest = band.max() else { return false }
        return Int(highest) - Int(lowest) < 24
    }

    private func capture(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
