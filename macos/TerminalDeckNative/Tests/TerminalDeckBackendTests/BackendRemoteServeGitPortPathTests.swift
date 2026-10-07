import XCTest
@testable import TerminalDeckBackend

final class BackendRemoteServeGitPortPathTests: XCTestCase {
    /// This is portable string formatting, not Windows filesystem/process work.
    func testWindowsShapedTextBecomesOneForwardSlashShellArgument() {
        XCTAssertEqual(BackendRemoteServeGitGuest.shellPath("C:\\Users\\x\\askpass.sh"), "'C:/Users/x/askpass.sh'")
    }
}
