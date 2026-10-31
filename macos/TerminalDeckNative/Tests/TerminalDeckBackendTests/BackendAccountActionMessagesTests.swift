import XCTest
@testable import TerminalDeckBackend

final class BackendAccountActionMessagesTests: XCTestCase {
    func testLockedStoreMessageNamesThePermissionButtonAndTheImmediateAlternative() {
        let text = BackendSessionSwitchKeptLogin.unavailableSentence
        XCTAssertTrue(text.contains("Settings › Coding AIs"))
        XCTAssertTrue(text.contains("click Allow login store"))
        XCTAssertTrue(text.contains("Always Allow"))
        XCTAssertTrue(text.contains("If this account is also signed in"))
        XCTAssertTrue(text.contains("New session › Login"))
        XCTAssertFalse(text.contains("once its sessions"))
        XCTAssertFalse(text.contains("sign the account in again"))
    }
}
