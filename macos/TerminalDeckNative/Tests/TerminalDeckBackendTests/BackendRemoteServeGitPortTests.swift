import XCTest
import Foundation
@testable import TerminalDeckBackend

final class BackendRemoteServeGitPortTests: XCTestCase {
    func testNoProxyClearsAllHelpersAndRequiresRepositoryPath() {
        let entries = BackendRemoteServeGitGuest.entries(.init(directory: URL(fileURLWithPath: "/tmp/device")))
        XCTAssertEqual(entries.filter { $0.0 == "credential.helper" }.map(\.1), [""])
        XCTAssertTrue(entries.contains { $0 == ("credential.useHttpPath", "true") })
    }
    func testNumberedOverridesAreCompleteAndNoStalePairIsCreated() {
        let plan = BackendRemoteServeGitGuest.environment(.init(directory: URL(fileURLWithPath: "/tmp/device")))
        let count = Int(plan.set["GIT_CONFIG_COUNT"] ?? "") ?? 0
        XCTAssertGreaterThan(count, 0)
        for index in 0..<count { XCTAssertFalse(plan.set["GIT_CONFIG_KEY_\(index)"]?.isEmpty ?? true); XCTAssertNotNil(plan.set["GIT_CONFIG_VALUE_\(index)"]) }
        XCTAssertNil(plan.set["GIT_CONFIG_KEY_\(count)"])
    }
    func testEnvironmentCarriesEndpointAndIdentifiesEveryPathVariable() {
        let request = BackendRemoteServeGitGuest.Request(directory: URL(fileURLWithPath: "/tmp/device"), link: .init(url: "http://127.0.0.1:49152/credential", key: String(repeating: "a", count: 64), helper: "/tmp/askpass.sh"))
        let plan = BackendRemoteServeGitGuest.environment(request)
        XCTAssertEqual(plan.set[BackendRemoteServeGitGuest.credentialURLVariable], request.link?.url); XCTAssertEqual(plan.set[BackendRemoteServeGitGuest.credentialKeyVariable], request.link?.key)
        XCTAssertTrue(plan.paths.contains("GIT_CONFIG_GLOBAL")); XCTAssertTrue(plan.paths.contains("GH_CONFIG_DIR"))
        for name in plan.paths { XCTAssertFalse(plan.set[name]?.isEmpty ?? true) }
        XCTAssertFalse(BackendRemoteServeGitGuest.askpassScript().contains(request.link!.key))
    }
    func testNoProxyCreatesOnlyDeviceConfigAndNoHelper() throws {
        let root = BackendRemoteServeAccountPortFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackendRemoteServeGitGuest.prepare(.init(directory: root.appendingPathComponent("device-c")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(BackendRemoteServeGitGuest.helperFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("device-c").appendingPathComponent(BackendRemoteServeGitGuest.helperFile).path))
    }
    func testMacHelperPathWithSpacesAndQuotesIsOneShellArgument() {
        XCTAssertEqual(BackendRemoteServeGitGuest.shellPath("/Users/x/Application Support/Terminal Deck/askpass.sh"), "'/Users/x/Application Support/Terminal Deck/askpass.sh'")
        XCTAssertEqual(BackendRemoteServeGitGuest.shellPath("/tmp/it's here/askpass.sh"), "'/tmp/it'\\''s here/askpass.sh'")
    }
}
