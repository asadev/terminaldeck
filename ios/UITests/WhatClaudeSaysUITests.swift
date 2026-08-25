import XCTest

/**
 * **Photograph what the agent actually prints**, rather than asserting about it.
 *
 * Asad: *"it happens as soon as i run claude in terminal"* — sessions on his
 * server open and then wear `exit 1`. `claude -p` over plain ssh on that same
 * machine exits 0, so the agent and its login are fine and the sandbox is where
 * the difference is. What is missing is the one thing nobody has: **the text on
 * the screen when it dies.** The host logs a session starting and never logs why
 * it ended, and no scrollback is kept on disk, so this is the only place that
 * sentence exists.
 *
 * So this asserts almost nothing on purpose. It starts a session, waits longer
 * than the failure needs, and writes the frames out. A test that guessed at the
 * message would fail on the wrong wording and tell me nothing; a picture of the
 * terminal tells me the cause in one read.
 */
final class WhatClaudeSaysUITests: XCTestCase {
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }

    func testStartOneAndPhotographWhateverItSays() throws {
        let app = XCUIApplication()
        app.launch()

        let out = app.buttons["copilot.back"].firstMatch
        if out.waitForExistence(timeout: 3), out.isHittable {
            out.tap()
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
        }

        try XCTSkipUnless(app.buttons["sessions.new"].waitForExistence(timeout: 25),
                          "no machine is paired with this simulator")
        save(app, "01-the-list-before")

        app.buttons["sessions.new"].tap()
        let plain = app.buttons["New session"].firstMatch
        if plain.waitForExistence(timeout: 5), plain.isHittable { plain.tap() }

        XCTAssertTrue(app.staticTexts["session.header"].firstMatch.waitForExistence(timeout: 60)
                      || app.otherElements["session.header"].firstMatch.waitForExistence(timeout: 5),
                      "the machine never opened the session this phone asked for")
        save(app, "02-opened")

        // Well past the point the corpses died at, and photographed on the way
        // so a failure that scrolls past is still caught in one of the frames.
        for step in 1 ... 6 {
            Thread.sleep(forTimeInterval: 5)
            save(app, "03-after-\(step * 5)s")
        }

        // Whatever is on the terminal, in text, so it lands in the log too.
        let words = app.descendants(matching: .any).allElementsBoundByIndex
            .prefix(120)
            .compactMap { $0.exists ? $0.label : nil }
            .filter { !$0.isEmpty }
        XCTContext.runActivity(named: "what the screen says") { activity in
            let dump = words.joined(separator: " | ")
            activity.add(XCTAttachment(string: dump))
            print("SCREEN-DUMP >>> \(dump.prefix(3000))")
        }
    }
}
