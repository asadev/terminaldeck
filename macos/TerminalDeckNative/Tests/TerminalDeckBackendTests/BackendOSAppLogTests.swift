import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSAppLogTests: XCTestCase {
    func testFormatFlattensLinesAndBoundsUTF16Payload() {
        let line = BackendOSLogRules.line(at: 0, level: "info", scope: "git", message: "first\r\nsecond", data: .object([.init("files", .number(3))]))
        XCTAssertTrue(line.hasPrefix("1970-01-01T00:00:00.000Z INFO  [git] first second"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(BackendOSLogRules.line(at: 0, level: "debug", scope: "", message: String(repeating: "x", count: 5000)).hasSuffix("… (truncated)"))
        XCTAssertEqual(BackendOSLogRules.requestedLines(.number(-1)), 1); XCTAssertEqual(BackendOSLogRules.requestedLines(.number(0)), 200); XCTAssertEqual(BackendOSLogRules.requestedLines(.number(5000)), 2000)
    }
    func testConstructorIsInertAndRotationTailKeepsChronologicalGenerations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSAppLog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try BackendOSAppLog(directory: root, fileName: "fixture.log", maximumBytes: 4096, keep: 2, redaction: .init(home: "/fixture-home", username: "fixture"), openPath: { _ in "" }, authorize: { _, _ in }, now: { 0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try await log.activate(oldLogOwnerDisabled: true)
        for index in 1...3 { _ = await log.write(level: "info", scope: "fixture", message: "entry-\(index) " + String(repeating: "x", count: 3900)) }
        let tail = try await log.tail(3)
        XCTAssertEqual(tail.count, 3); XCTAssertTrue(tail[0].contains("entry-1")); XCTAssertTrue(tail[2].contains("entry-3"))
        let zero = try await log.tail(0); XCTAssertTrue(zero.isEmpty)
        let status = await log.status(); XCTAssertEqual(status["files"].elements?.count, 3)
        try await log.clear(); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/fixture.log"))
    }
    func testSecretFieldsAreRemovedBeforePersistenceAndWriterOwnershipIsRequired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSAppLog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try BackendOSAppLog(directory: root, fileName: "fixture.log", redaction: .init(home: "/fixture-home", extraSecrets: ["fixture-secret-value"]), openPath: { _ in "" }, authorize: { _, _ in })
        let before = await log.write(level: "info", scope: "fixture", message: "hello"); XCTAssertFalse(before)
        try await log.activate(oldLogOwnerDisabled: true)
        _ = await log.write(level: "info", scope: "fixture", message: "fixture-secret-value", data: .object([.init("apiKey", .string("fixture-secret-value"))]))
        let persisted = try String(contentsOf: root.appendingPathComponent("fixture.log"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("fixture-secret-value")); XCTAssertTrue(persisted.contains("[redacted]"))
    }
}
