import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppSessionTestPortRules: XCTestCase, @unchecked Sendable {
    private var boundary: BackendAppSessionBoundary {
        .init(folder: "/Users/apple/granted", readable: ["/Users/apple/granted", "/Users/apple/Library/Application Support/x/device-homes/abc", "/usr", "/bin"], readableFiles: ["/Users/apple/Library/Application Support/x/helper.sh"], readableProjects: ["/Users/apple/Projects/thing"])
    }
    func testBoundaryUnnotedSession() async { let value = await BackendAppSessionBoundaryRegistry().boundary(for: "never-noted"); XCTAssertNil(value) }
    func testBoundaryCopiesFolderAndReachableLists() async {
        let registry = BackendAppSessionBoundaryRegistry(); await registry.note("s1", boundary: boundary)
        let value = await registry.boundary(for: "s1")
        XCTAssertEqual(value?.folder, "/Users/apple/granted")
        XCTAssertTrue(value?.readable.contains("/Users/apple/granted") == true)
        XCTAssertTrue(value?.readable.contains("/usr") == true)
        XCTAssertTrue(value?.readableFiles.contains("/Users/apple/Library/Application Support/x/helper.sh") == true)
        XCTAssertEqual(value?.readableProjects, ["/Users/apple/Projects/thing"])
    }
    func testBoundaryForgetOnExit() async { let registry = BackendAppSessionBoundaryRegistry(); await registry.note("s2", boundary: boundary); await registry.forget("s2"); let value = await registry.boundary(for: "s2"); XCTAssertNil(value) }
    func testBoundaryGrantedFolderAndDescendants() { XCTAssertTrue(boundary.allows("/Users/apple/granted")); XCTAssertTrue(boundary.allows("/Users/apple/granted/src/main.ts")) }
    func testBoundaryDesktopHomeAndOtherProjectRefused() { for path in ["/Users/apple/Desktop/shot.png", "/Users/apple/.ssh/id_ed25519", "/Users/apple/Projects/other/README.md"] { XCTAssertFalse(boundary.allows(path)) } }
    func testBoundaryPrefixSiblingRefused() { XCTAssertFalse(boundary.allows("/Users/apple/granted-old/x.txt")) }
    func testBoundaryIndividualFileDoesNotGrantSiblings() { XCTAssertTrue(boundary.allows("/Users/apple/Library/Application Support/x/helper.sh")); XCTAssertFalse(boundary.allows("/Users/apple/Library/Application Support/x/other-device.conf")) }
    func testProbePathEvidence() { let value = BackendAppSessionToolProbe.result(bin: "claude", command: "which claude", stdout: "/Users/apple/.local/bin/claude\n", stderr: "", exitCode: 0); XCTAssertTrue(value.found); XCTAssertEqual(value.line, "/Users/apple/.local/bin/claude") }
    func testProbeOutputThreeLinesAnd240Units() { let value = BackendAppSessionToolProbe.result(bin: "gemini", command: "which gemini", stdout: "a\nb\nc\nd\ne\n", stderr: String(repeating: "x", count: 500) + "\n", exitCode: 1); XCTAssertEqual(value.output.components(separatedBy: "\n").count, 3); XCTAssertLessThanOrEqual(value.output.utf16.count, 240) }
    func testUnsafeNameNeverReachesFakeExecutor() async {
        let executor = BackendAppSessionTestPortExecutor([]), probe = BackendAppSessionToolProbe(executor: executor, environment: [:], home: "/fixture")
        let value = await probe.probe("claude; rm -rf ~", path: "/fixture/bin")
        XCTAssertFalse(value.found); XCTAssertTrue(value.line.contains("not a name this app is willing to run"))
        let calls = await executor.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testMacLaunchSpecUsesDirectNameEvenForOddCmdExtension() {
        let ordinary = BackendAppSessionToolProbe.macLaunchSpec("claude", resolved: "/opt/homebrew/bin/claude")
        XCTAssertEqual(ordinary.command, "claude"); XCTAssertFalse(ordinary.shell)
        XCTAssertFalse(BackendAppSessionToolProbe.macLaunchSpec("claude", resolved: "/opt/homebrew/bin/claude.cmd").shell)
        let absent = BackendAppSessionToolProbe.macLaunchSpec("copilot")
        XCTAssertEqual(absent.command, "copilot"); XCTAssertFalse(absent.shell)
    }
}
