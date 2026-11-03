import XCTest
@testable import TerminalDeckNative

final class ChatPastSearchTests: XCTestCase {
    func testMatchingFiltersAndInvalidQuery() throws {
        let tools = try NativeChatPastSearch.request(cwd: "/project", query: "needle", scope: "project", role: "tool")
        XCTAssertEqual(tools["roles"].elements?.compactMap(\.string), ["tool"])
        XCTAssertEqual(tools["scope"].string, "project")
        let all = try NativeChatPastSearch.request(cwd: "/project", query: "needle", scope: "all", role: "all")
        XCTAssertEqual(all["roles"].elements?.compactMap(\.string), ["user", "assistant", "tool"])
        XCTAssertThrowsError(try NativeChatPastSearch.request(cwd: "/project", query: " ", scope: "all", role: "all"))
    }
}
