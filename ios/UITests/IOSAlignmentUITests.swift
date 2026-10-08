import XCTest

final class IOSAlignmentUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testStructuredQuestionRequiresValuesBeforeApproval() {
        let app = XCUIApplication()
        app.launchArguments = ["--ios-alignment-preview"]
        app.launch()
        app.openTab("Hoot")
        let field = app.textFields["copilot.composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Ask a form")
        app.buttons["copilot.send"].tap()
        let allow = app.buttons["copilot.consent.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertFalse(allow.isEnabled)
        let name = app.secureTextFields["Name"].exists ? app.secureTextFields["Name"] : app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Asad")
        XCTAssertTrue(allow.isEnabled)
        shot("Hoot required form")
        allow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["copilot.consent.settled"].waitForExistence(timeout: 5))
        shot("Hoot form settled")
    }

    func testStructuredHootChatAndProjectTaskActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ios-alignment-preview"]
        app.launch()
        app.openTab("Hoot")
        XCTAssertTrue(app.staticTexts["I’m Hoot. You can review your work and talk to me here."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["copilot.status"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["copilot.run"].exists)
        shot("Hoot conversation")

        let textView = app.textViews["copilot.composer"].firstMatch
        let composer = textView.exists ? textView : app.textFields["copilot.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Review my tasks")
        app.buttons["copilot.send"].tap()
        XCTAssertTrue(app.staticTexts["I received your message: Review my tasks"].waitForExistence(timeout: 10))
        shot("Hoot reply")

        // The chat keeps its keyboard after Send. Leave it through its own
        // Back control before reaching the tab bar underneath.
        app.buttons["copilot.back"].tap()
        XCTAssertTrue(app.openSettingsTab())
        let work = app.buttons["settings.projectWork"]
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        work.tap()
        XCTAssertTrue(app.buttons["work.tasks"].waitForExistence(timeout: 5))
        shot("Project work")
        app.buttons["work.tasks"].tap()
        XCTAssertTrue(app.staticTexts["Review phone layout"].waitForExistence(timeout: 5))
        shot("Tasks before changes")
        app.buttons["panel.tasks.act.add"].tap()
        let title = app.textFields["panel.form.field.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Phone UI proof")
        app.buttons["panel.form.submit"].tap()
        XCTAssertTrue(app.staticTexts["Phone UI proof"].waitForExistence(timeout: 5))
        shot("Tasks after add")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
