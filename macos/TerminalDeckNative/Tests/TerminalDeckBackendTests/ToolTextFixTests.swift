import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ToolTextFixTests: XCTestCase {
    func testLiftRequestDescribesTheHumanApprovalPath() throws {
        let tool = try XCTUnwrap(BackendBrowserScrapingMCP.tools().first { $0.id == "browser.lift_request" })
        XCTAssertFalse(tool.description.contains("currently pending"))
        XCTAssertTrue(tool.description.contains("person can approve"))
        XCTAssertTrue(tool.description.contains("filing an ask never copies login data"))
    }

    func testCoverageExplainsOwnerSettingsAndKeepsTheirAudienceRestriction() throws {
        let actions = ["ai-apps:level", "ai-apps:ask-first", "ai-apps:folders", "ai-apps:tasks",
                       "ai-apps:create", "ai-apps:revoke", "ai-apps:internet", "plugins:allow",
                       "plugins:enable", "plugins:remove"]
        for action in actions {
            let row = try XCTUnwrap(BackendDeckCoreCatalogueCoverage.rows.first { $0.action == action })
            XCTAssertNil(row.tools, action)
            XCTAssertFalse(try XCTUnwrap(row.skip, action).isEmpty, action)
            XCTAssertTrue(row.skip?.contains("Settings") == true, action)
            XCTAssertTrue(row.wireValue["audience"].string?.contains("Hoot only") == true, action)
        }
        let skipped = try BackendDeckCoreCatalogueCoverage.answer(.object([.init("skippedOnly", .bool(true)), .init("query", .string("ai-apps:level"))]))
        XCTAssertEqual(skipped.value["matched"].number, 1)
    }
}
