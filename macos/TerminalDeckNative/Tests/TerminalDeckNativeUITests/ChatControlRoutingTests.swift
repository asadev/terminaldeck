import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatControlRoutingTests: XCTestCase {
    func testSettingsCommandsSelectTheirExactControlsAndRejectUnknown() throws {
        let model = NativeHootChatModel(fixture: .object([]))
        for (command, target) in [("model", "model"), ("reasoning", "effort"), ("permissions", "permissions"), ("approve", "permissions")] {
            XCTAssertEqual(try model.controlsTool("open", request: command)["openControl"].string, target)
        }
        XCTAssertThrowsError(try model.controlsTool("open", request: "not-real"))
        XCTAssertEqual(try model.controlsTool("close", request: nil)["openControl"], .null)
        XCTAssertEqual(HootSlashCommand.appControls["model"], "Chat model picker")
    }
}
