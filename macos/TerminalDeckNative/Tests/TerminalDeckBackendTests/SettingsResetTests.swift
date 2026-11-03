import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// SETTINGS-TRUTH row 58: Settings › Advanced › Start over resets the app's settings, but keeps every project's own
/// settings and the protected keys (a reset used to turn remote access back on, and lost project settings).
final class SettingsResetTests: XCTestCase {
    func testStartOverKeepsProjectSettingsAndProtectedKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-settings-reset-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("remote.enabled", .bool(false)), .init("hoot.provider", .string("codex")),
                                           .init("appearance.density", .string("compact")), .init("general.copyOnSelect", .bool(true))]))
        _ = try await store.patchProject("imatch", values: .object([.init("about", .string("Dating app"))]))

        let reset = try await store.reset()
        XCTAssertEqual(reset["values"], .object([.init("remote.enabled", .bool(false)), .init("hoot.provider", .string("codex"))]))
        await store.resetCache()   // read back from the file, as the next start does
        let read = await store.get()
        XCTAssertEqual(read["values"]["remote.enabled"], .bool(false), "remote access stays off")
        XCTAssertTrue(read["values"]["appearance.density"].isNullish)
        XCTAssertTrue(read["values"]["general.copyOnSelect"].isNullish)
        let project = await store.projectSettings("imatch")
        XCTAssertEqual(project["values"]["about"], .string("Dating app"), "project settings are kept")
    }
}
