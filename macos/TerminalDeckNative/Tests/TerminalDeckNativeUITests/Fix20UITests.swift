import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class Fix20UITests: XCTestCase {
    func testCodexChatActionsOpenControlsAndHideTerminalOnlyScreens() {
        let names = ["model", "permissions", "status", "compact", "review", "init", "plan", "project-check", "mcp", "exit", "vim", "resume"]
        let commands = HootSlashCommand.offered(.array(names.map { .object([.init("name", .string($0))]) }))
        XCTAssertEqual(commands.map(\.name), Array(names.prefix(8)))
        for name in ["model", "permissions", "status"] { XCTAssertNotNil(commands.first { $0.name == name }?.opensInApp) }
        XCTAssertNil(commands.first { $0.name == "project-check" }?.opensInApp)
        XCTAssertEqual(HootSlashCommand.matches(commands, query: "project").map(\.name), ["project-check"])
    }
}
