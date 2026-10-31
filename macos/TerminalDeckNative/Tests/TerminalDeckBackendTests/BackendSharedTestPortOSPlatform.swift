import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Only the existing argument parser and provisional path/report helpers.
/// No test here claims legacy state-copy or full HostFacts coverage.
final class BackendSharedTestPortOSPlatform: XCTestCase {
    func testUserDataFlagReadsBothSpellings() {
        XCTAssertEqual(NativePlatformPaths.userDataFlag(["electron", "--user-data-dir=/tmp/probe"]), "/tmp/probe")
        XCTAssertEqual(NativePlatformPaths.userDataFlag(["electron", "--user-data-dir", "/tmp/probe"]), "/tmp/probe")
    }
    func testUserDataFlagAbsenceEmptyAndFollowingFlag() {
        XCTAssertNil(NativePlatformPaths.userDataFlag(["electron", "."]))
        XCTAssertNil(NativePlatformPaths.userDataFlag(["electron", "--user-data-dir="]))
        XCTAssertNil(NativePlatformPaths.userDataFlag(["electron", "--user-data-dir", "--inspect"]))
        XCTAssertNil(NativePlatformPaths.userDataFlag(["electron", "--user-data-dir"]))
    }
    func testProvisionalUserDataRootSelectionOnlySupplement() {
        let home = URL(fileURLWithPath: "/fixture-home"), pinned = URL(fileURLWithPath: "/fixture-support/terminaldeck")
        XCTAssertEqual(BackendOSUserData.root(home: home, arguments: [], current: pinned), pinned)
        XCTAssertEqual(BackendOSUserData.root(home: home, arguments: ["app", "--user-data-dir=/tmp/probe"], current: pinned).path, "/tmp/probe")
        // Source pinUserData(current:/fixture-support/Pawl) must preserve the
        // current parent and copy state. The existing helper instead chooses
        // home Application Support; this is its supplemental policy, not proof
        // of the missing migration and therefore is not asserted as a source case.
    }
    func testProvisionalMacReachabilityReportExactSourceBranch() {
        XCTAssertEqual(BackendOSPlatform.platform, "darwin")
        XCTAssertEqual(BackendOSPlatform.reachability, .object([
            .init("kind", .string("macos")), .init("headline", .string("Handled by the desktop build on this Mac, not here.")),
            .init("detail", .array([
                .string("Terminal Deck’s desktop build holds the wake lock and watches the battery, and it can do both from a window that is already running. A headless host on the same machine would be a second thing holding the same lock."),
                .string("Run the headless host here for what it is good at — a machine with no screen, or one you drive entirely from a phone — and leave staying-awake to the app."),
            ])), .init("steps", .array([])), .init("atRisk", .bool(false)),
        ]))
        XCTAssertTrue(BackendOSPlatform.reachability["detail"].elements?.compactMap(\.string).joined(separator: " ").contains("desktop build") == true)
        XCTAssertTrue(BackendOSPlatform.reachability["headline"].string?.contains("Mac") == true)
    }
}
