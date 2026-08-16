/**
 * The session sheet, on a real screen.
 *
 * `SessionDetailsTests` pins the sentences. What it cannot pin is the two things
 * that make this screen exist at all, and both are facts about a running app:
 *
 *  - **It is reachable without knowing a gesture.** The long press on a list row
 *    is the shortcut; the named item inside the session is the way somebody
 *    finds it. A feature that only has the gesture is a feature nobody has.
 *  - **The folder is on it, whole.** The list row truncates a path from the head
 *    because a row has no space; the whole point of the sheet is that it does.
 *
 * Runs against the same stand-in the dev-server suite uses and pairs itself the
 * same way:
 *
 *     ios/Harness/run.sh host --approve-after 3000 \
 *         --rendezvous wss://relay.terminaldeck.dev --folders /tmp/td-devdemo &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/SessionDetailUITests
 *
 * It skips rather than fails with nothing listening, like the rest of this
 * target.
 */

import XCTest

final class SessionDetailUITests: XCTestCase {

    private static let control = URL(string: "http://127.0.0.1:8788")!

    private var app: XCUIApplication!
    private static var reachable: Bool?

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        if app.textFields["pairing.field"].waitForExistence(timeout: 5) {
            guard let data = try? Data(contentsOf: Self.control.appendingPathComponent("pair")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? String else {
                Self.reachable = false
                throw XCTSkip(Self.notRunning)
            }
            let field = app.textFields["pairing.field"]
            field.tap()
            field.typeText(code)
            app.buttons["pairing.submit"].tap()
        }

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 15)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    private static let notRunning =
        "No harness. Start ios/Harness/run.sh host --approve-after 3000 "
        + "--rendezvous wss://relay.terminaldeck.dev and run again."

    /**
     * The named way in, from inside the session.
     *
     * This is the path that has to work for somebody who has never long-pressed
     * anything, and it is the one a screenshot of the menu would not prove —
     * a menu item that presents nothing looks identical to one that presents
     * something, right up until the frame after the tap.
     */
    func testTheSessionMenuOpensTheDetailsSheet() throws {
        try openASession()

        app.buttons["terminal.actions"].tap()
        let item = app.buttons["terminal.details"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the session menu should offer its details")
        item.tap()

        // The folder card is the reason the sheet exists, so it is the thing
        // waited on rather than the navigation title — a sheet that came up
        // empty would satisfy a title.
        XCTAssertTrue(app.buttons["detail.folder"].waitForExistence(timeout: 10),
                      "the sheet should show the folder this session runs in")
        XCTAssertTrue(app.staticTexts["detail.status"].exists,
                      "and what it is doing")
        save("detail-01-from-the-session-menu")

        app.buttons["detail.done"].tap()
        XCTAssertTrue(app.buttons["terminal.actions"].waitForExistence(timeout: 10),
                      "Done should leave the session underneath it")
    }

    /// The shortcut. A long press on a row, which must not also navigate into
    /// the session — a context menu that opens a screen behind itself is one
    /// people back out of twice.
    func testLongPressingARowOffersTheSameSheet() throws {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 20), "no sessions to press")
        rows.element(boundBy: 0).press(forDuration: 1.2)

        let details = app.buttons["session.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), "a long press should offer Details")
        details.tap()

        XCTAssertTrue(app.buttons["detail.folder"].waitForExistence(timeout: 10))
        // Reached from the list, so there is somewhere to go — the button is
        // absent when the sheet was raised from inside the session itself.
        XCTAssertTrue(app.buttons["detail.open"].exists,
                      "from the list, the sheet should offer to open the session")
        save("detail-02-from-a-long-press")
        app.buttons["detail.done"].tap()
    }

    // MARK: - Helpers

    private func openASession() throws {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        if rows.count == 0 {
            let plus = app.buttons["sessions.new"]
            XCTAssertTrue(plus.waitForExistence(timeout: 15), "no sessions and no way to start one")
            plus.tap()
            let menuItem = app.buttons["sessions.newDefault"]
            if menuItem.waitForExistence(timeout: 3) { menuItem.tap() }
        }
        let first = rows.element(boundBy: 0)
        if first.waitForExistence(timeout: 25), !app.buttons["terminal.actions"].exists {
            first.tap()
        }
        XCTAssertTrue(app.buttons["terminal.actions"].waitForExistence(timeout: 20),
                      "the terminal screen should be open")
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
