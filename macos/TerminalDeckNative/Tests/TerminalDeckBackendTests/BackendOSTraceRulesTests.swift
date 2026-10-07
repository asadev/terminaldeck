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
}
