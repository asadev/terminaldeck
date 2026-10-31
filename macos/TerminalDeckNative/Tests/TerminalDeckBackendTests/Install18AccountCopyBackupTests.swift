import Foundation
import XCTest
@testable import TerminalDeckBackend

final class Install18AccountCopyBackupTests: XCTestCase, @unchecked Sendable {
    func testRemoveCopyMovesWholeHistoryToBackupWithoutChangingBytes() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let copy = try await f.create("Copy")
            let folder = URL(fileURLWithPath: copy.configDir)
            let history = Data("first conversation\nsecond conversation\n".utf8)
            let plans = folder.appendingPathComponent("plans")
            try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
            try history.write(to: folder.appendingPathComponent("history.jsonl"))
            try Data("saved plan".utf8).write(to: plans.appendingPathComponent("plan.md"))
            let backup = try XCTUnwrap(BackendAccountCopyBackup.archive(copy, configuration: f.configuration, stamp: "proof18"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("history.jsonl")), history)
            XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("plans/plan.md"), encoding: .utf8), "saved plan")
            try BackendAccountCopyBackup.restore(backup, profile: copy)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("history.jsonl")), history)
        }
    }

    func testRemoveCopyFacadeRemovesMetadataAndVaultSlotAndKeepsHistory() async throws {
        let r = try await BackendF4Runtime.wire()
        do {
            let copy = try await r.create("copy@example.com")
            let other = try await r.create("other@example.com")
            _ = await r.put(copy.id, BackendF4ClaudeLogin("fixture-copy"))
            _ = await r.put(other.id, BackendF4ClaudeLogin("fixture-other"))
            let history = URL(fileURLWithPath: copy.configDir).appendingPathComponent("history.jsonl")
            try Data("keep all conversations".utf8).write(to: history)
            let answer = try await r.rpc.invoke("profiles:remove-copy", args: [.string(copy.id)], context: BackendF4Runtime.context)
            XCTAssertEqual(answer["removed"].bool, true)
            let backup = try XCTUnwrap(answer["backupPath"].string)
            XCTAssertEqual(try String(contentsOfFile: backup + "/history.jsonl", encoding: .utf8), "keep all conversations")
            let removed = try await r.profiles.find(copy.id)
            let keptOther = try await r.profiles.find(other.id)
            XCTAssertEqual(keptOther?.id, other.id)
            let copySlot = await r.vault.has(copy.id), otherSlot = await r.vault.has(other.id)
            XCTAssertNil(removed); XCTAssertFalse(copySlot); XCTAssertTrue(otherSlot)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.configDir))
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }

    func testRemoveCopyRefusesPendingAndLiveUseWithoutChangingLoginOrHistory() async throws {
        let r = try await BackendF4Runtime.wire()
        do {
            let copy = try await r.create("copy@example.com")
            _ = await r.put(copy.id, BackendF4ClaudeLogin("fixture-copy"))
            let history = URL(fileURLWithPath: copy.configDir).appendingPathComponent("history.jsonl")
            try Data("in-use conversation".utf8).write(to: history)
            var input = BackendCreateSessionInput(cwd: r.root.path, provider: "claude")
            input.profileId = copy.id
            let launch = try await r.adapter.resolve(input, provider: BackendProviderSpec(id: "claude", command: "/fixture/never-run", args: [], resumeArgs: []),
                loginPath: "/usr/bin:/bin", context: BackendLaunchContext(isAppComposed: true))
            do { _ = try await r.adapter.removeCopy(id: copy.id); XCTFail("A pending account must stay in place") }
            catch { XCTAssertTrue(error.localizedDescription.contains("in use")) }
            let meta = BackendSessionMeta(id: "fixture-live", input: input,
                spawn: BackendSpawnSpec(provider: "claude", command: "/fixture/never-run", args: [], path: "/usr/bin:/bin"))
            try await r.adapter.bind(launch, session: meta)
            do { _ = try await r.adapter.removeCopy(id: copy.id); XCTFail("A live account must stay in place") }
            catch { XCTAssertTrue(error.localizedDescription.contains("in use")) }
            let kept = try await r.profiles.find(copy.id), held = await r.vault.has(copy.id)
            XCTAssertNotNil(kept); XCTAssertTrue(held)
            XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "in-use conversation")
            await r.adapter.exited(sessionID: meta.id)
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }

    func testRemoveCopyRefusesLockedVaultAndLeavesBothProfilesAndSlotsAndFolder() async throws {
        let cipher = Install18LockableCipher()
        let r = try await BackendF4Runtime.wire(cipher: cipher)
        do {
            let copy = try await r.create("copy@example.com"), other = try await r.create("other@example.com")
            _ = await r.put(copy.id, BackendF4ClaudeLogin("fixture-copy"))
            _ = await r.put(other.id, BackendF4ClaudeLogin("fixture-other"))
            let file = await r.vault.file, original = try Data(contentsOf: file)
            let history = URL(fileURLWithPath: copy.configDir).appendingPathComponent("history.jsonl")
            try Data("locked conversation".utf8).write(to: history)
            cipher.setLocked(true)
            await r.vault.reload()
            do { _ = try await r.adapter.removeCopy(id: copy.id); XCTFail("A locked vault must keep its account") }
            catch { XCTAssertTrue(error.localizedDescription.contains("locked")) }
            let kept = try await r.profiles.find(copy.id), keptOther = try await r.profiles.find(other.id)
            XCTAssertNotNil(kept); XCTAssertNotNil(keptOther)
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "locked conversation")
            cipher.setLocked(false)
            await r.vault.reload()
            let held = await r.vault.has(copy.id), heldOther = await r.vault.has(other.id)
            XCTAssertTrue(held); XCTAssertTrue(heldOther)
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }

    func testMetadataSaveFailureRestoresCopyFolderAndItsVaultSlot() async throws {
        let r = try await BackendF4Runtime.wire()
        let file = r.configuration.dataDirectory.appendingPathComponent("profiles.json")
        let heldFile = r.configuration.dataDirectory.appendingPathComponent("profiles-held.json")
        do {
            let copy = try await r.create("copy@example.com"), other = try await r.create("other@example.com")
            _ = await r.put(copy.id, BackendF4ClaudeLogin("fixture-copy"))
            _ = await r.put(other.id, BackendF4ClaudeLogin("fixture-other"))
            let history = URL(fileURLWithPath: copy.configDir).appendingPathComponent("history.jsonl")
            try Data("save failure conversation".utf8).write(to: history)
            try FileManager.default.moveItem(at: file, to: heldFile)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            do { _ = try await r.adapter.removeCopy(id: copy.id); XCTFail("A failed metadata save cannot report removal") }
            catch { /* The persistence failure must reach the caller. */ }
            let kept = try await r.profiles.find(copy.id), keptOther = try await r.profiles.find(other.id)
            let held = await r.vault.has(copy.id), heldOther = await r.vault.has(other.id)
            XCTAssertNotNil(kept); XCTAssertNotNil(keptOther); XCTAssertTrue(held); XCTAssertTrue(heldOther)
            XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "save failure conversation")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: heldFile, to: file)
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }

    func testCopyBackupRejectsSystemExternalAndLinkedFolders() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            var profile = f.profile("copy")
            profile.system = true
            XCTAssertThrowsError(try BackendAccountCopyBackup.archive(profile, configuration: f.configuration))
            profile.system = false; profile.configDir = f.configuration.homeDirectory.path
            XCTAssertThrowsError(try BackendAccountCopyBackup.archive(profile, configuration: f.configuration))
            let linked = f.configuration.profilesRoot.appendingPathComponent("linked")
            try FileManager.default.createDirectory(at: f.configuration.profilesRoot, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: f.configuration.homeDirectory)
            profile.configDir = linked.path
            XCTAssertThrowsError(try BackendAccountCopyBackup.archive(profile, configuration: f.configuration))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.configuration.homeDirectory.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path), f.configuration.homeDirectory.path)
        }
    }
}

private final class Install18LockableCipher: BackendAccountVaultCipher, @unchecked Sendable {
    private let locked = BackendF4Box(false)
    func setLocked(_ value: Bool) { locked.value = value }
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { BackendF4FakeCipher.encrypt(text) }
    func decrypt(_ blob: Data) throws -> String {
        guard !locked.value else { throw BackendAccountFailure("Fixture account vault is locked") }
        return try BackendF4FakeCipher.decrypt(blob)
    }
}
