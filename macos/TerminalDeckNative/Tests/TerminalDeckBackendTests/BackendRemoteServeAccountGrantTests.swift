import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeAccountGrantTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-remote-grants-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testAbsentAllAndNoneRemainDifferent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open()
        let absent = await trust.remoteServeAccountGrant("guest"), allowed = await trust.hasAnyAccount("guest")
        XCTAssertNil(absent); XCTAssertTrue(allowed)
        try await trust.remoteServeSetAccountGrants("guest", mode: .string("selected"), accounts: [])
        let none = await trust.remoteServeAccountGrant("guest"), any = await trust.hasAnyAccount("guest")
        XCTAssertEqual(none?.accounts, []); XCTAssertFalse(any)
        try await trust.remoteServeSetAccountGrants("guest", mode: .string("all"), accounts: [.string("old")])
        let all = await trust.remoteServeAccountGrant("guest"), added = await trust.accountAllowed("guest", account: "new")
        XCTAssertEqual(all?.accounts, []); XCTAssertTrue(all?.all == true); XCTAssertTrue(added)
        await trust.close()
    }
    func testCleaningBoundsAndPersistenceSchema() async throws {
        let trimmed = BackendRemoteServeAccountGrantStorage.clean([.string("\u{FEFF}bom\u{FEFF}"), .string("\u{0085}nel\u{0085}")], maximum: 64, length: 200)
        XCTAssertEqual(trimmed, ["bom", "\u{0085}nel\u{0085}"])
        let folderTrimmed = BackendRemoteServeSessionPolicy.cleanFolders([.string("\u{FEFF}/work/bom\u{FEFF}"), .string("/work/nel\u{0085}"), .string("\u{0085}/work/relative")])
        XCTAssertEqual(folderTrimmed, ["/work/bom", "/work/nel\u{0085}"])
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open()
        let grant = try await trust.remoteServeSetAccountGrants("guest", mode: .string("nonsense"), accounts: [.string("work"), .string("work"), .null, .number(7), .string("  spaced  "), .string(String(repeating: "x", count: 201))])
        XCTAssertEqual(grant.accounts, ["work", "spaced"]); XCTAssertFalse(grant.all)
        let file = root.appendingPathComponent("remote-accounts.json"), data = try Data(contentsOf: file)
        XCTAssertEqual(data.last, 0x0A)
        let raw = try NativeRPCValue.parseJSON(data)
        XCTAssertEqual(raw["version"], .number(1)); XCTAssertEqual(raw["devices"]["guest"]["mode"], .string("selected"))
        XCTAssertEqual(raw["devices"]["guest"]["accounts"], .array([.string("work"), .string("spaced")]))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        await trust.close()
        let reopened = BackendRemoteTrustStore(directory: root); try await reopened.open(); try await reopened.remoteServeReloadDomainGrants()
        let restored = await reopened.remoteServeAccountGrant("guest")
        XCTAssertEqual(restored?.accounts, ["work", "spaced"]); await reopened.close()
    }
    func testMalformedRowNarrowsAndMalformedFileReturnsAbsence() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("remote-accounts.json")
        try Data(#"{"devices":{"guest":{"mode":"everything","accounts":["work",7]},"":{},"bad":3}}"#.utf8).write(to: file)
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open(); try await trust.remoteServeReloadDomainGrants()
        let guest = await trust.remoteServeAccountGrant("guest"), rows = await trust.remoteServeAccountGrants()
        XCTAssertEqual(guest?.accounts, ["work"]); XCTAssertEqual(rows.count, 1)
        try Data("{bad json".utf8).write(to: file); try await trust.remoteServeReloadDomainGrants()
        let absent = await trust.remoteServeAccountGrant("guest"), any = await trust.hasAnyAccount("guest")
        XCTAssertNil(absent); XCTAssertTrue(any); await trust.close()
    }
    func testPruningDoesNotWidenAnyOtherDevice() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open()
        try await trust.remoteServeSetAccountGrants("a", mode: .string("selected"), accounts: [.string("deleted")])
        try await trust.remoteServeSetAccountGrants("b", mode: .string("selected"), accounts: [.string("work")])
        let changed = try await trust.remoteServeDropAccount("deleted"), again = try await trust.remoteServeDropAccount("deleted")
        XCTAssertTrue(changed); XCTAssertFalse(again)
        let a = await trust.hasAnyAccount("a"), b = await trust.remoteServeAccountGrant("b")
        XCTAssertFalse(a); XCTAssertEqual(b?.accounts, ["work"])
        let forgotten = try await trust.remoteServeForgetAccountGrants("a"), twice = try await trust.remoteServeForgetAccountGrants("a")
        XCTAssertTrue(forgotten); XCTAssertFalse(twice); await trust.close()
    }
    func testFailedCommitDoesNotPublishMemoryChoice() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open()
        try await trust.remoteServeSetAccountGrants("guest", mode: .string("selected"), accounts: [.string("old")])
        let file = root.appendingPathComponent("remote-accounts.json")
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await trust.remoteServeSetAccountGrants("guest", mode: .string("all"), accounts: []); XCTFail("A failed disk write must throw") } catch {}
        let held = await trust.remoteServeAccountGrant("guest")
        XCTAssertEqual(held?.accounts, ["old"]); XCTAssertFalse(held?.all == true); await trust.close()
    }
    func testSessionIncludeAndDropPreserveSelection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open()
        let absent = try await trust.remoteServeIncludeStartedSession("phone", sessionID: "new")
        XCTAssertFalse(absent)
        try await trust.remoteServeSetSessionGrants("phone", mode: .string("selected"), sessions: [])
        let empty = try await trust.remoteServeIncludeStartedSession("phone", sessionID: ""), over = try await trust.remoteServeIncludeStartedSession("phone", sessionID: String(repeating: "x", count: 129))
        XCTAssertFalse(empty); XCTAssertFalse(over)
        let first = try await trust.remoteServeIncludeStartedSession("phone", sessionID: "new"), twice = try await trust.remoteServeIncludeStartedSession("phone", sessionID: "new")
        XCTAssertTrue(first); XCTAssertFalse(twice)
        let other = await trust.sessionShared("other", session: "new")
        XCTAssertTrue(other)
        let dropped = try await trust.remoteServeDropSession("new"), row = await trust.remoteServeSessionGrant("phone")
        XCTAssertTrue(dropped); XCTAssertEqual(row?.sessions, []); XCTAssertFalse(row?.all == true); await trust.close()
    }
    func testOnlyNewDeviceRowsMeetTheSixtyFourDeviceCeiling() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open()
        for index in 0..<64 { try await trust.remoteServeSetSessionGrants("d\(index)", mode: .string("selected"), sessions: []) }
        try await trust.remoteServeSetSessionGrants("extra", mode: .string("all"), sessions: [])
        try await trust.remoteServeSetSessionGrants("d0", mode: .string("all"), sessions: [])
        let count = await trust.remoteServeSessionGrants().count, extra = await trust.remoteServeSessionGrant("extra"), edited = await trust.remoteServeSessionGrant("d0")
        XCTAssertEqual(count, 64); XCTAssertNil(extra); XCTAssertTrue(edited?.all == true); await trust.close()
    }
    func testFolderStoreKeepsEmptyAndOriginalSpelling() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root); try await trust.open()
        let folders = try await trust.remoteServeSetFolderGrants("phone", folders: [.string("/work/A"), .string("/work/A/"), .string("/work/a"), .string("relative"), .null])
        XCTAssertEqual(folders, ["/work/A", "/work/a"])
        try await trust.remoteServeSetFolderGrants("phone", folders: [])
        let empty = await trust.grantedFolders("phone"), absent = await trust.grantedFolders("other")
        XCTAssertEqual(empty, []); XCTAssertNil(absent); await trust.close()
    }
}
