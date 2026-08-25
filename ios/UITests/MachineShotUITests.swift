import XCTest
final class MachineShotUITests: XCTestCase {
    func testMachinePage() throws {
        let app = XCUIApplication(); app.launch()
        let shots = ProcessInfo.processInfo.environment["TD_SHOTS"] ?? ""
        func grab(_ n: String) {
            let s = XCUIScreen.main.screenshot()
            if !shots.isEmpty { try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(n).png")) }
        }
        XCTAssertTrue(app.openSettingsTab())
        XCTAssertTrue(app.buttons["settings.machines"].waitForExistence(timeout: 15))
        app.buttons["settings.machines"].tap()
        grab("20-machines")
        let info = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'machine.about.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10), "every machine row should lead somewhere")
        info.tap()
        _ = app.staticTexts["Kind"].waitForExistence(timeout: 10)
        grab("21-machine-detail")
    }
}
