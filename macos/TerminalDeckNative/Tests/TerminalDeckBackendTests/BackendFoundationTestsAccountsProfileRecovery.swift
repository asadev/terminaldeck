import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Source backup/recovery expectations (profiles.ts getState/persist): an
/// unreadable, corrupt or newer file boots as what could be read and is moved
/// to `profiles.json.bak-<ms>` exactly once, before the first write.
final class BackendFoundationTestsAccountsProfileRecovery: XCTestCase, @unchecked Sendable {
    private let realState = #"{"version":1,"profiles":[{"id":"work","name":"Work","configDir":"/tmp/w"},{"id":"personal","name":"Personal","configDir":"/tmp/p"}],"defaultProfileId":"work","projectDefaults":{"/repo":"work"}}"#
    private func backups(_ f: BackendFoundationTestsAccountsFixture) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: f.configuration.dataDirectory.path).filter { $0.contains("profiles.json.bak-") } }
    // profiles.test.ts:554
    func testCorruptStateBootsAsEmpty() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        try await BackendFoundationTestsAccountsWithReloadedProfiles(f, bytes: Data("{ not json".utf8)) { store in let snapshot = try await store.snapshot(); XCTAssertEqual(snapshot.profiles, []) }
    } }
    // profiles.test.ts:750
    func testCorruptStateIsBackedUpBeforeFirstWrite() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let corrupt = Data(realState.dropLast(20).utf8)
        try await BackendFoundationTestsAccountsWithReloadedProfiles(f, bytes: corrupt) { store in
            let snapshot = try await store.snapshot(); XCTAssertEqual(snapshot.profiles, [])
            _ = try await store.create(name: "New", vaultManaged: false)
            let saved = try backups(f); XCTAssertEqual(saved.count, 1)
            let file = try XCTUnwrap(saved.first), text = try String(contentsOf: f.configuration.dataDirectory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("\"Work\"")); XCTAssertTrue(text.contains("\"Personal\""))
        }
    } }
    // profiles.test.ts:775 (Mac mode-bit fixture, no live files).
    func testUnreadableValidStateIsBackedUpWhenItBecomesReadable() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        await f.profiles.close()
        let file = f.configuration.dataDirectory.appendingPathComponent("profiles.json")
        try Data(realState.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let reloaded: BackendAccountProfileStore
        do { reloaded = try BackendAccountProfileStore(configuration: f.configuration, stateStore: f.state) }
        catch { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path); throw error }
        do {
            let snapshot = try await reloaded.snapshot(); XCTAssertEqual(snapshot.profiles, [])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            _ = try await reloaded.create(name: "New", vaultManaged: false)
            let saved = try backups(f); XCTAssertEqual(saved.count, 1)
            let name = try XCTUnwrap(saved.first), text = try String(contentsOf: f.configuration.dataDirectory.appendingPathComponent(name), encoding: .utf8); XCTAssertTrue(text.contains("\"personal\"")); await reloaded.close()
        } catch { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path); await reloaded.close(); throw error }
    } }
    // profiles.test.ts:814
    func testNewerStateHasBackupBeforeRewrite() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        try await BackendFoundationTestsAccountsWithReloadedProfiles(f, bytes: Data(#"{"version":99,"profiles":[]}"#.utf8)) { store in _ = try await store.create(name: "Work", vaultManaged: false); XCTAssertEqual(try backups(f).count, 1) }
    } }
    // profiles.test.ts:832
    func testCorruptBackupIsMadeExactlyOnce() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        try await BackendFoundationTestsAccountsWithReloadedProfiles(f, bytes: Data("{ not json".utf8)) { store in _ = try await store.create(name: "One", vaultManaged: false); _ = try await store.create(name: "Two", vaultManaged: false); try await store.setDefault(nil); XCTAssertEqual(try backups(f).count, 1) }
    } }
}
