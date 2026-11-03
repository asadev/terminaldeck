import XCTest
@testable import TerminalDeckNative
import TerminalDeckNativeCore

@MainActor
final class RemoteDeviceDefaultsTests: XCTestCase {
    func testUnreadDeviceScreensKeepLoadingStateAndDefaultChoices() {
        let folders = RemoteFoldersModel(), sessions = RemoteSessionsModel(), logins = RemoteLoginsModel()
        XCTAssertNil(folders.grants)
        XCTAssertNil(folders.problem)
        XCTAssertFalse(folders.granting)
        XCTAssertNil(sessions.choices)
        XCTAssertTrue(sessions.running.isEmpty)
        XCTAssertEqual(sessions.choice("new-device"), .all)
        XCTAssertEqual(logins.choice("new-device"), .all)
        sessions.stop()
        sessions.stop()
        XCTAssertNil(sessions.busy)
    }
}
