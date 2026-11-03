import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Applied with the writer patch, never linked before DKA integrates it.
@MainActor final class SFXWriterRegressionTests: XCTestCase {
    func testErrorJSONIncludesEngineMessageAndHintWithoutClaimingReady() {
        let raw = NativeRPCValue.object([.init("error", .object([
            .init("message", .string("The settings cannot be read.")),
            .init("hint", .string("Restore the saved settings from Git."))]))])
        let result = BackendStaysFixedRead.setup(raw, roots: [], failure: nil)
        XCTAssertEqual(result["ok"], .bool(false))
        XCTAssertTrue(result["problem"].string?.contains("The settings cannot be read.") == true)
        XCTAssertTrue(result["problem"].string?.contains("Restore the saved settings from Git.") == true)
        XCTAssertTrue(result["problem"].string?.contains("Finish setup") == true)
        XCTAssertEqual(result["readiness"], .null)
    }

    func testLegacySuccessWithoutOKIsPreservedButExplicitFailureIsNot() {
        let legacy = NativeRPCValue.object([.init("written", .array([.string("/sample/staysfixed.config.js")]))])
        XCTAssertEqual(BackendStaysFixedRead.setup(legacy, roots: ["/sample"], failure: nil)["ok"], .bool(true))
        XCTAssertEqual(BackendStaysFixedRead.setup(legacy, roots: ["/sample"], failure: nil)["wrote"], .array([.string("staysfixed.config.js")]))
        let failed = legacy.setting("ok", .bool(false)).setting("problems", .array([.string("Disk full.")]))
        let result = BackendStaysFixedRead.setup(failed, roots: ["/sample"], failure: nil)
        XCTAssertEqual(result["ok"], .bool(false))
        XCTAssertEqual(result["wrote"], .array([.string("staysfixed.config.js")]))
        XCTAssertTrue(result["problem"].string?.contains("Disk full.") == true)
        XCTAssertTrue(result["problem"].string?.contains("Finish setup") == true)
    }

    func testServiceRejectsNonzeroTimeoutCancellationAndMissingOK() async throws {
        let cases: [(Int32?, Bool, Bool, String)] = [
            (1, false, false, "{\"ok\":true,\"written\":[]}"),
            (0, true, false, "{\"ok\":true,\"written\":[]}"),
            (0, false, true, "{\"ok\":true,\"written\":[]}"),
            (0, false, false, "{\"error\":{\"message\":\"Bad settings\",\"hint\":\"Restore from Git.\"}}"),
        ]
        for (code, timedOut, cancelled, stdout) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SFX-writer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let driver = SFXWriterDriver(result: .init(code: code, stdout: stdout, stderr: "", timedOut: timedOut, cancelled: cancelled))
            let service = BackendStaysFixedService(userData: root.appendingPathComponent("app-data"), home: root.path,
                executable: "/fixture/node", inheritedEnvironment: [:], locate: { driver.home },
                loginPath: { "/usr/bin:/bin" }, driverFactory: { _, _, _, _, _ in driver })
            let result = try await service.setup(root.path)
            XCTAssertEqual(result["ok"], .bool(false))
            XCTAssertTrue(result["problem"].string?.contains("Try setup again") == true)
            let arguments = await driver.arguments
            XCTAssertEqual(arguments, ["init", "--json", "--offline"])
        }
    }
}

private actor SFXWriterDriver: BackendStaysFixedEngineRunning {
    nonisolated let home = BackendStaysFixedEngineHome(dir: URL(fileURLWithPath: "/fixture"),
        bin: URL(fileURLWithPath: "/fixture/bin"), version: "0.15.0", versionNote: "")
    let result: BackendStaysFixedRunResult
    var arguments: [String] = []
    init(result: BackendStaysFixedRunResult) { self.result = result }
    func cli(_ args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult {
        arguments = args; return result
    }
    func script(_ source: String, args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult { result }
}
