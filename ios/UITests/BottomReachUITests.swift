import XCTest

/**
 * Can you actually reach the bottom row of a scrolling screen?
 *
 * On iOS 26 the tab bar is a floating pill and content is **meant** to scroll
 * under it — a screenshot taken mid-scroll with a row behind the pill is the
 * design working, not a bug. The question a picture cannot answer is whether the
 * *last* row clears the pill once the scroll is finished, which is a bottom
 * content inset and is invisible until you are at the end.
 *
 * So this scrolls to the end and asks whether the final row's centre sits above
 * the pill's top edge. It exists because the alternative was reporting a defect
 * off a mid-scroll frame.
 */
final class BottomReachUITests: XCTestCase {
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard !shots.isEmpty else { return }
        let shot = app.screenshot()
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }

    /// The pill's top edge, or the screen bottom when there is no pill.
    private func pillTop(_ app: XCUIApplication) -> CGFloat {
        let bar = app.tabBars.firstMatch
        guard bar.exists else { return app.frame.maxY }
        return bar.frame.minY
    }

    private func reachBottom(_ app: XCUIApplication, _ label: String) {
        var lastCount = -1
        for _ in 0 ..< 12 {
            let cells = app.cells.count + app.buttons.count
            app.swipeUp(velocity: .fast)
            if cells == lastCount { break }
            lastCount = cells
        }
        save(app, "bottom-\(label)")

        // The lowest element that is actually on screen.
        let all = app.descendants(matching: .any).allElementsBoundByIndex
        let onScreen = all.filter { $0.exists && $0.frame.height > 8 && $0.frame.width > 40 && $0.isHittable }
        guard let lowest = onScreen.max(by: { $0.frame.maxY < $1.frame.maxY }) else { return }
        let top = pillTop(app)
        XCTAssertLessThanOrEqual(
            lowest.frame.midY, top,
            "\(label): the last reachable element's centre (\(lowest.frame.midY)) is under the tab bar (\(top)) — "
                + "the scroll has no bottom inset for the floating pill"
        )
    }

    func testTheBottomOfSettingsIsReachable() {
        let app = XCUIApplication()
        app.launch()

        /*
         * The tabs carry an `.accessibilityLabel` inside `.tabItem`, not an
         * identifier — `DeckTabs.pill` sets it deliberately, so "Menu" is the
         * address. The first version of this guessed `tab.settings`, found
         * nothing, returned early and reported **success with no screenshots**:
         * a green run in which nothing was tested, which is the worst thing a
         * probe can do. Hence the assertion rather than a guard.
         */
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25),
                      "the Menu tab never appeared — this probe tested nothing")
        menu.tap()
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 10),
                      "the Menu tab drew nothing")
        reachBottom(app, "settings")
    }
}
