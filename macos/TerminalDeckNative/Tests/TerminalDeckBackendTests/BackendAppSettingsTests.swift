import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppSettingsTests: XCTestCase {
    func testPrimitiveCapsAndPatchDeletion() {
        let value = NativeRPCValue.object([.init("__proto__", .string("bad")), .init("a", .bool(true)), .init("b", .number(12)),
            .init("c", .string(String(repeating: "x", count: 4200))), .init("nested", .object([])), .init("nan", .number(.nan))])
        let cleaned = BackendAppSettingsStore.sanitize(value)
        XCTAssertFalse(cleaned.has("__proto__")); XCTAssertFalse(cleaned.has("nested")); XCTAssertFalse(cleaned.has("nan"))
        XCTAssertEqual(cleaned["c"].string?.utf16.count, 4096)
        let patched = BackendAppSettingsStore.applyPatch(cleaned, .object([.init("a", .null), .init("b", .array([]))]))
        XCTAssertFalse(patched.has("a")); XCTAssertEqual(patched["b"], .number(12))
        let many = NativeRPCValue.object((0..<520).map { .init("k\($0)", .number(Double($0))) })
        XCTAssertEqual(BackendAppSettingsStore.sanitize(many).fields?.count, 500)
    }
    func testCorruptBackupFutureFieldsAndLastGoodSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppSettings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data("{ corrupt".utf8).write(to: file)
        let store = BackendAppSettingsStore(userData: root, writable: true, now: { 1791280000123 })
        let empty = await store.get(); XCTAssertEqual(empty["values"], .object([]))
        _ = try await store.patch(.object([.init("a", .number(1))]))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: file.path + ".bak-1791280000123"), encoding: .utf8), "{ corrupt")
        try Data(#"{"version":99,"values":{"a":1},"future":{"keep":true}}"#.utf8).write(to: file)
        await store.resetCache()
        _ = try await store.patch(.object([.init("b", .number(2))]))
        let persisted = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        XCTAssertEqual(persisted["future"]["keep"], .bool(true))
        _ = try await store.snapshot(preferences: .object([.init("theme", .string("dark"))]), reason: "copilot settings.write")
        let snapshot = try NativeRPCValue.parseJSON(Data(contentsOf: root.appendingPathComponent("settings.last-good.json")))
        XCTAssertEqual(snapshot["settings"]["future"]["keep"], .bool(true))
        XCTAssertEqual(snapshot["fromCache"], .bool(false)); XCTAssertEqual(snapshot["preferences"]["theme"], .string("dark"))
    }
    func testFailedWriteLeavesCachedValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppSettings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("a", .number(1))]))
        try FileManager.default.removeItem(at: root)
        try Data("blocks directory".utf8).write(to: root)
        do { _ = try await store.patch(.object([.init("a", .number(2))])); XCTFail("Write must fail") } catch {}
        let current = await store.get(); XCTAssertEqual(current["values"]["a"], .number(1))
    }
    func testRepositoryNormalizationAndMissingBrowser() async {
        XCTAssertEqual(BackendAppSettingsChannels.repositoryURL(.string("asadev/terminaldeck")), "https://github.com/asadev/terminaldeck")
        XCTAssertEqual(BackendAppSettingsChannels.repositoryURL(.string("git@github.com:asadev/terminaldeck.git")), "https://github.com/asadev/terminaldeck")
        XCTAssertNil(BackendAppSettingsChannels.repositoryURL(.string("not a repo")))
        let root = URL(fileURLWithPath: "/tmp/BackendAppSettings-unused")
        let env = BackendAppSettingsEnvironment(userData: root, logs: root, trace: root, browser: nil, about: { .null }, publish: { _, _ in })
        let result = await BackendAppSettingsChannels.clearBrowserData(env)
        XCTAssertEqual(result["cleared"], .bool(false)); XCTAssertTrue(result["message"].string?.contains("unavailable") == true)
        let store = BackendAppSettingsStore(userData: root)
        let kept = await BackendAppSettingsChannels.clearIfNotPersisting(store: store, environment: env)
        XCTAssertEqual(kept["message"], .string("Browsing data is kept between runs."))
    }
}
