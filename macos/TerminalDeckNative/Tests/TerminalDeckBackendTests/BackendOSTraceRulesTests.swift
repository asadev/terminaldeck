import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSTraceRulesTests: XCTestCase {
    func testDisabledBootDiscardsOldTraceAndToggleWorksWithoutRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSTrace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ipc-trace.log"), previous = root.appendingPathComponent("ipc-trace.log.1")
        try Data("stale".utf8).write(to: file); try Data("older".utf8).write(to: previous)
        let trace = try BackendOSTrace(userData: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        let silent = await trace.invokeStarted(channel: "a:b", arguments: []); XCTAssertFalse(silent)
        await trace.setEnabled(true)
        let started = await trace.invokeStarted(channel: "a:b", arguments: [.string("x")])
        await trace.invokeReturned(channel: "a:b", value: .number(1), started: started)
        let text = try String(contentsOf: file, encoding: .utf8); XCTAssertTrue(text.contains("trace started")); XCTAssertTrue(text.contains("← a:b ok: 1"))
        await trace.setEnabled(false); await trace.sent(channel: "a:b", arguments: [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }
    func testRotationBoundsTwoGenerationsAndExcludesNoise() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSTrace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ipc-trace.log"), previous = root.appendingPathComponent("ipc-trace.log.1")
        try Data(repeating: 122, count: BackendOSTrace.maximumBytes - 20).write(to: file)
        let trace = try BackendOSTrace(userData: root, enabled: true)
        let excluded = await trace.invokeStarted(channel: "browser:bounds", arguments: []); XCTAssertFalse(excluded)
        _ = await trace.invokeStarted(channel: "session:list", arguments: [.string(String(repeating: "x", count: 4000))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertLessThan(try Data(contentsOf: file).count, BackendOSTrace.maximumBytes)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("→ browser:bounds"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["ipc-trace.log", "ipc-trace.log.1"])
    }

    /// #168: Debug mode's trace hides secrets (the one shared rule) and never records what is typed.
    func testTraceHidesSecretsAndTypedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSTrace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let trace = try BackendOSTrace(userData: root, enabled: true), token = "ghp_" + String(repeating: "A1b2", count: 6)
        let started = await trace.invokeStarted(channel: "mcp:save", arguments: [.object([.init("password", .string("hunter2 horse")), .init("note", .string("use \(token) here"))])])
        await trace.invokeReturned(channel: "mcp:save", value: .object([.init("apiKey", .string("plainvalue123"))]), started: started)
        await trace.invokeThrew(channel: "mcp:save", error: NativeRPCError(code: "refused", message: "rejected Bearer \(token)"), started: started)
        await trace.sent(channel: "session:write", arguments: [.string("s1"), .string("hunter2\r")])
        // A value cut at the length limit never leaves the start of a secret behind.
        _ = await trace.invokeStarted(channel: "a:long", arguments: [.string(String(repeating: "a ", count: 95) + token)])
        let text = try String(contentsOf: root.appendingPathComponent("ipc-trace.log"), encoding: .utf8)
        for secret in ["hunter2", "plainvalue123", "ghp_"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertTrue(text.contains("→ mcp:save("))
        XCTAssertTrue(text.contains("⇢ session:write(\(BackendOSTrace.typedWithheld))"))
        XCTAssertTrue(text.contains(BackendSharedRedact.redacted))
    }
    /// #168: the app's own calls are traced while Debug mode is on, and the switch works without a restart.
    func testDebugModeSwitchTracesTheAppsCalls() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSTrace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: data) }
        let graph = try BackendCompositionRoot(dataRoot: data, state: NativeStateStore(), environment: ["HOME": data.path, "PATH": "/nonexistent"], home: data.path)
        let file = data.standardizedFileURL.appendingPathComponent("ipc-trace.log")
        let environment = BackendAppSettingsEnvironment(userData: data.standardizedFileURL, logs: data.appendingPathComponent("logs"), trace: file,
            browser: nil, about: { .null }, publish: { channel, value in try? await graph.registry.publish(channel, arguments: [value]) })
        _ = try await graph.installSettings(environment: environment)
        let trace = await graph.trace
        XCTAssertNotNil(trace)
        let app = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)
        _ = try await graph.invoke("settings:get", context: app, arguments: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "off by default")
        _ = try await graph.invoke("settings:set", context: app, arguments: [.object([.init(BackendOSTrace.setting, .bool(true))])])
        _ = try await graph.invoke("settings:get", context: app, arguments: [])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("→ settings:get("))
        _ = try await graph.invoke("settings:set", context: app, arguments: [.object([.init(BackendOSTrace.setting, .bool(false))])])
        let after = try String(contentsOf: file, encoding: .utf8)
        _ = try await graph.invoke("settings:paths", context: app, arguments: [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), after, "switched off, nothing more is written")
        try await graph.shutdown()
    }
}
