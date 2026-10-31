import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class GHScreenFixTests: XCTestCase {
    func testRepositoryPagesDoNotShrinkPickerAndResetClearsListState() {
        let model = NativeGHWorkspaceModel(cwd: "/fixture", pageFocus: nil)
        let repos = (1...80).map { NativeGHItem(raw: .object(["id": .number(Double($0))]), area: .repos, fallbackRepo: "") }
        model.mergeRepositories(repos)
        model.mergeRepositories(Array(repos.prefix(50)))
        XCTAssertEqual(model.repositories.count, 80)
        model.items = repos; model.query = "repo"; model.page = 3; model.hasMore = true
        model.resetList()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.page, 1)
        XCTAssertFalse(model.hasMore)
    }

    func testNotificationLinksUseOnlyKnownWebPaths() {
        func subject(_ type: String, _ path: String) -> CodingAIJSON {
            .object(["type": .string(type), "url": .string("https://api.github.com/repos/owner/repo/" + path)])
        }
        XCTAssertEqual(NativeGHDetailModel.notificationLink(subject("Commit", "commits/abc")), "https://github.com/owner/repo/commit/abc")
        XCTAssertNil(NativeGHDetailModel.notificationLink(subject("Release", "releases/123")))
        XCTAssertNil(NativeGHDetailModel.notificationLink(subject("CheckSuite", "check-suites/123")))
        XCTAssertNil(NativeGHDetailModel.notificationLink(subject("Unknown", "things/123")))
    }
}
