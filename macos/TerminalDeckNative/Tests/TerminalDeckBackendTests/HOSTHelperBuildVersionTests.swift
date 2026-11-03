// QUIT (9 Oct 2026): every local build of one marketing version reused "0.20.2-host3/"; the
// next build's helper was refused and new sessions ran in-app. One folder per helper build now.
#if TD_HOST_INTEGRATED
import Foundation
import XCTest
@testable import TerminalDeckBackend

final class HOSTHelperBuildVersionTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-ver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testDifferentHelperBuildsOfOneMarketingVersionGetDifferentFolders() throws {
        let root = try scratch()
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two"), same = root.appendingPathComponent("same")
        try Data("helper build one".utf8).write(to: one); try Data("helper build two".utf8).write(to: two); try Data("helper build one".utf8).write(to: same)
        let a = try BackendHOSTLaunchAgent.buildVersion(marketing: "0.20.2-host3", helper: one)
        let b = try BackendHOSTLaunchAgent.buildVersion(marketing: "0.20.2-host3", helper: two)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, try BackendHOSTLaunchAgent.buildVersion(marketing: "0.20.2-host3", helper: same)) // same bytes: same folder, reused
        XCTAssertTrue(a.hasPrefix("0.20.2-host3-")); XCTAssertEqual(a.count, "0.20.2-host3-".count + 12)
        // Every produced version is accepted by the launch plan's own identity rule.
        let paths = try BackendHOSTPaths(dataDirectory: root)
        XCTAssertNoThrow(try BackendHOSTLaunchAgent(paths: paths, version: a, launchAgentsDirectory: root))
        XCTAssertNoThrow(try BackendHOSTLaunchAgent(paths: paths, version: try BackendHOSTLaunchAgent.buildVersion(marketing: "beta 1/x", helper: one), launchAgentsDirectory: root))
    }
    func testPruneRemovesOnlyOtherHelperOnlyBuildFolders() throws {
        let host = try scratch()
        func folder(_ name: String, files: [String]) throws {
            let dir = host.appendingPathComponent(name); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in files { try Data("x".utf8).write(to: dir.appendingPathComponent(file)) }
        }
        try folder("0.20.2-host3", files: ["TerminalDeckNativeHelper"])              // an older build: removed
        try folder("0.20.2-host3.replaced-0154build", files: ["TerminalDeckNativeHelper"]) // removed
        try folder("0.20.2-host3-aaaaaaaaaaaa", files: ["TerminalDeckNativeHelper"]) // the current build: kept
        try folder("agents", files: [])                                               // the agents namespace: kept
        try folder("agents/0.20.2-host3", files: ["TerminalDeckNativeHelper"])       // not this namespace: kept
        try folder("odd", files: ["TerminalDeckNativeHelper", "notes.txt"])           // anything else inside: kept
        try Data("s".utf8).write(to: host.appendingPathComponent("secret"))
        let removed = BackendHOSTLaunchAgent.pruneOtherHelpers(in: host, keeping: "0.20.2-host3-aaaaaaaaaaaa").sorted()
        XCTAssertEqual(removed, ["0.20.2-host3", "0.20.2-host3.replaced-0154build"])
        let left = try FileManager.default.contentsOfDirectory(atPath: host.path).sorted()
        XCTAssertEqual(left, ["0.20.2-host3-aaaaaaaaaaaa", "agents", "odd", "secret"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.appendingPathComponent("agents/0.20.2-host3/TerminalDeckNativeHelper").path))
    }
}
#endif
