import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendUIGSessionSimulatorHeadlessExecutor: BackendAppSessionCommandExecuting {
    var calls: [(String, [String])] = []
    var launched = false
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) -> BackendAppSessionCommandResult {
        calls.append((command, arguments))
        if arguments == ["devices"] { return .init(stdout: launched ? "emulator-5554 device\n" : "", exitCode: 0) }
        if arguments.contains("sys.boot_completed") { return .init(stdout: "1\n", exitCode: 0) }
        return .init(exitCode: 0)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) {
        calls.append((command, arguments)); launched = true
    }
    func captured() -> [(String, [String])] { calls }
}

final class BackendUIGSessionSimulatorHeadlessTests: XCTestCase, @unchecked Sendable {
    func testActualSharedIOSBootNeverOpensSimulatorApp() async throws {
        let executor = BackendUIGSessionSimulatorHeadlessExecutor()
        let platform = BackendAppDevicePlatform(environment: [:], home: "/fixture", executor: executor)
        let id = "ios:" + UUID().uuidString, result = await platform.boot(id)
        XCTAssertEqual(result["ok"].bool, true)
        let calls = await executor.captured()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.0), ["xcrun", "xcrun"])
        XCTAssertEqual(calls[0].1, ["simctl", "boot", String(id.dropFirst(4))])
        XCTAssertEqual(calls[1].1, ["simctl", "bootstatus", String(id.dropFirst(4)), "-b"])
        XCTAssertFalse(calls.flatMap { [$0.0] + $0.1 }.contains { $0 == "open" || $0.contains("Simulator.app") || $0 == "-a" })
    }
    func testActualSharedAndroidBootUsesNoWindow() async throws {
        let sdk = FileManager.default.temporaryDirectory.appendingPathComponent("UIG-sdk-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sdk) }
        for relative in ["emulator/emulator", "platform-tools/adb"] {
            let file = sdk.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let executor = BackendUIGSessionSimulatorHeadlessExecutor()
        let platform = BackendAppDevicePlatform(environment: ["ANDROID_HOME": sdk.path], home: "/fixture", executor: executor)
        let result = await platform.boot("avd:td-sim-fixture")
        XCTAssertEqual(result["ok"].bool, true)
        let calls = await executor.captured()
        let launch = try XCTUnwrap(calls.first { $0.0.hasSuffix("emulator/emulator") })
        XCTAssertEqual(launch.1, ["-avd", "td-sim-fixture", "-no-boot-anim", "-no-window", "-gpu", "host"])
    }
}
