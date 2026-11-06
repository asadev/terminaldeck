import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackgroundItemsTests: XCTestCase {
    func testScratchNamespacesUseTheirOwnAppIdentity() throws {
        let root = URL(fileURLWithPath: "/tmp/bg-items-plan")
        for namespace: String? in [nil, "agents"] {
            let paths = try BackendHOSTPaths(dataDirectory: root, namespace: namespace)
            let plan = try BackendHOSTLaunchAgent(paths: paths, version: "v1", launchAgentsDirectory: root,
                appBundleIdentifier: "dev.terminaldeck.review.unique")
            let raw = try XCTUnwrap(PropertyListSerialization.propertyList(from: plan.propertyList(), format: nil) as? [String: Any])
            XCTAssertEqual(raw["AssociatedBundleIdentifiers"] as? [String], ["dev.terminaldeck.review.unique"])
            let fallback = try BackendHOSTLaunchAgent(paths: paths, version: "v1", launchAgentsDirectory: root,
                appBundleIdentifier: "dev.terminaldeck.app")
            XCTAssertNotEqual(fallback.associatedBundleIdentifier, "dev.terminaldeck.app")
        }
    }

    func testCleanupProtectsOtherCopiesAndKeepsFilesWhenUnloadFails() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repo.appendingPathComponent("macos/dev/scratch-launch-agents-test.py").path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }
}
