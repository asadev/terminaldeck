/**
 * Naming a port, with a finger.
 *
 * It used to fold a group as well. There are no groups now — *"this other
 * services and web services should not be like separate lists, it should be one
 * list"* — so the case that pressed `localhost.section.other` is gone with the
 * header it pressed.
 *
 * `PortCatalogTests` and `PortBookTests` pin the rules and the storage without a
 * simulator. What they cannot reach is the half that only exists on a screen:
 * that the swipe is there at all, that the alert it raises writes through to the
 * store, and that the row it was raised from comes back saying something
 * different. Those are the three ways this feature can be completely correct
 * underneath and do nothing when it is touched.
 *
 * ## Running it
 *
 * The same harness `DevServerUITests` uses, plus anything at all listening — the
 * suite renames whichever port the machine offers first rather than naming a
 * number, because a number chosen independently of the thing that serves it is a
 * suite that fails on a machine where everything works:
 *
 *     node .harness/.devsite/server.mjs &            # anything listening will do
 *     ios/Harness/run.sh host --approve-after 3000 &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/LocalhostGroupingUITests
 *
 * It skips rather than fails when there is nothing to talk to, for the reason
 * the rest of this target does: a suite that goes red on a laptop with no server
 * running is a suite that gets deleted in a week.
 *
 * ## Not yet run
 *
 * Written and compiled against a machine with no harness on it, so every case
 * here has skipped rather than passed. Each one therefore asserts that it
 * *arrived* before it asserts anything else — a query that turns out to be wrong
 * fails on the line that names what it was looking for, rather than silently
 * doing nothing and failing somewhere unrelated afterwards.
 */

import XCTest

final class LocalhostGroupingUITests: XCTestCase {

    /// Where `ios/Harness/run.sh host` puts its control server: the relay's port
    /// plus one. The same one `DevServerUITests` names.
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

        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")
    }

    private static let notRunning =
        "No harness. Start ios/Harness/run.sh host --approve-after 3000, with something "
        + "listening on the machine, and run again."

    // MARK: - Naming

    /**
     * The whole of his complaint, and the whole of the fix.
     *
     * *"we will not be able to know which one holds what stuff… we should be
     * able to maybe rename them."* A row that said a process name says a
     * sentence afterwards, and it says it after the app has been closed and
     * opened — a name that only lives in a view is a name that is gone the next
     * time somebody looks.
     */
    func testRenamingAPortSticksAndSurvivesARelaunch() throws {
        let row = try firstPortRow()
        let port = try portNumber(of: row)

        app.swipeRight(on: row)
        let rename = app.buttons["port.swipe.rename.\(port)"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5),
                      "a swipe from the leading edge should offer Rename")
        rename.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Rename should raise the naming alert")
        // No identifier on the field: SwiftUI drops one on the way to
        // `UIAlertController`, which is why `renameFirstMachine` reaches for the
        // first text field too.
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the alert should have a field to type in")
        field.tap()
        field.typeText("Harness page")
        alert.buttons["port.rename.save"].firstMatch.tap()

        let named = app.staticTexts["Harness page"]
        XCTAssertTrue(named.waitForExistence(timeout: 10),
                      "the row should be drawn under its new name")
        // Naming still lifts a port to the top of the list — the name is the pin
        // — but there is no *Named by you* header to look for any more, so the
        // row under its new name is the whole of what can be asserted here.

        app.terminate()
        app.launch()
        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation, and it should survive a relaunch")
        XCTAssertTrue(app.staticTexts["Harness page"].waitForExistence(timeout: 20),
                      "the name should have outlived the app")

        // Put it back, so a second run of this suite starts where the first did.
        clearName(port: port)
    }

    // MARK: - Folding

    // MARK: - Helpers

    /// The first port row on screen, whatever number it is. Named by prefix
    /// because the port a machine happens to be serving on is not knowable from
    /// here, and a suite that hard-coded one would pass or fail by luck.
    private func firstPortRow() throws -> XCUIElement {
        let row = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'port.' AND NOT identifier CONTAINS 'menu'"))
            .firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("nothing is listening on the machine, so there is no port row to name")
        }
        return row
    }

    private func portNumber(of row: XCUIElement) throws -> String {
        let identifier = row.identifier
        guard identifier.hasPrefix("port.") else {
            throw XCTSkip("a row without a port identifier: \(identifier)")
        }
        return String(identifier.dropFirst("port.".count))
    }

    /// Undo the name through the app's own control, so the next run of this
    /// suite sees the machine as it found it.
    private func clearName(port: String) {
        let menu = app.buttons["port.more.\(port)"]
        guard menu.waitForExistence(timeout: 5) else { return }
        menu.tap()
        let clear = app.buttons["port.menu.clear"]
        guard clear.waitForExistence(timeout: 5) else {
            app.tap()
            return
        }
        clear.tap()
    }

    private func pairingCode() throws -> String {
        guard let data = try? Data(contentsOf: Self.control.appendingPathComponent("pair")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else {
            Self.reachable = false
            throw XCTSkip(Self.notRunning)
        }
        return code
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
}

private extension XCUIApplication {
    /// A swipe from the leading edge, aimed at the middle of a row.
    ///
    /// `XCUIElement.swipeRight()` starts at the element's own centre, which on a
    /// full-width row is far enough in that the gesture is read as a scroll. This
    /// presses at the left edge and drags across, which is what a thumb does.
    func swipeRight(on element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
