import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/account-vault/store.test.ts against the real BackendAccountVault,
/// a fake cipher and a temporary data folder. A second vault over the same file is
/// opened only after the first is closed: the native writer lease allows one writer.
final class BackendFoundationTestsF4AccountsStore: XCTestCase, @unchecked Sendable {
    private let credentials = "keychain:Claude Code-credentials"

    // store.test.ts:24
    func testRoundTripsALoginThroughTheDiskWithoutEverWritingThePlaintext() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f)
        let login = BackendF4ClaudeLogin("ACCOUNT-ONE")
        let put = await vault.write(accountID: "work", provider: "claude", slot: credentials, value: login, source: "sign-in")
        XCTAssertTrue(put.ok)
        let onDisk = try String(contentsOf: vault.file, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("ACCOUNT-ONE")); XCTAssertFalse(onDisk.contains("accessToken"))
        await vault.close()
        let again = try BackendF4Vault(f)
        let read = await again.readSlot("work", slot: credentials); XCTAssertEqual(read, login)
        let has = await again.has("work"); XCTAssertTrue(has)
        await again.close()
    } }

    // store.test.ts:39 (the vault's own folder; the vault makes it, owner-only, on the first write)
    func testWritesTheFileOwnerOnlyAtomicallyWithNoTempFileLeftBehind() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f)
        let dir = vault.directory
        _ = await vault.write(accountID: "work", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("A"), source: "sign-in")
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: vault.file.path)[.posixPermissions] as? NSNumber).intValue
        let dirMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600); XCTAssertEqual(dirMode & 0o777, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }, [])
        await vault.close()
    } }

    // store.test.ts:47
    func testHoldsAnyNumberOfAccountsForEveryAgentEachWithItsOwnLogin() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f)
        for i in 0..<40 {
            _ = await vault.write(accountID: "claude-\(i)", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("C\(i)"), source: "sign-in")
            _ = await vault.write(accountID: "codex-\(i)", provider: "codex", slot: "file:auth.json", value: "{\"tokens\":{\"access_token\":\"X\(i)\"}}", source: "sign-in")
        }
        await vault.close()
        let again = try BackendF4Vault(f)
        let count = await again.allSummaries().count; XCTAssertEqual(count, 80)
        let claude = await again.readSlot("claude-17", slot: credentials); XCTAssertEqual(claude, BackendF4ClaudeLogin("C17"))
        let codex = await again.readSlot("codex-39", slot: "file:auth.json"); XCTAssertTrue(codex?.contains("X39") == true)
        // One account's slot never answers for another's.
        let crossed = await again.readSlot("claude-17", slot: "file:auth.json"); XCTAssertNil(crossed)
        await again.close()
    } }

    // store.test.ts:61
    func testARefreshReplacesTheValueAndWritingTheSameValueAgainTouchesNothing() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let now = BackendF4Box<Double>(1_000), writes = BackendF4Box(0)
        let vault = try BackendF4Vault(f, now: { now.value }, writeFile: { data, file in writes.update { $0 += 1 }; try data.write(to: file) })
        _ = await vault.write(accountID: "work", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("OLD"), source: "sign-in")
        now.value = 2_000
        let same = await vault.write(accountID: "work", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("OLD"), source: "refresh")
        XCTAssertEqual(same, BackendAccountVaultWrite(ok: true, changed: false, message: ""))
        XCTAssertEqual(writes.value, 1)
        now.value = 3_000
        _ = await vault.write(accountID: "work", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("NEW"), source: "refresh")
        XCTAssertEqual(writes.value, 2)
        let read = await vault.readSlot("work", slot: credentials); XCTAssertEqual(read, BackendF4ClaudeLogin("NEW"))
        let summary = await vault.summary("work")
        XCTAssertEqual(summary?.capturedAt, 1_000); XCTAssertEqual(summary?.updatedAt, 3_000); XCTAssertEqual(summary?.lastSource, "refresh")
        await vault.close()
    } }

    // store.test.ts:90
    func testForgetDeletesEverySecretTheAccountHadFromMemoryAndFromDisk() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f)
        _ = await vault.write(accountID: "gone", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("GONE"), source: "sign-in")
        _ = await vault.write(accountID: "gone", provider: "claude", slot: "keychain:Claude Code", value: "sk-ant-api03-GONE", source: "typed")
        _ = await vault.write(accountID: "kept", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("KEPT"), source: "sign-in")
        let forgot = await vault.forgetAccount("gone"); XCTAssertTrue(forgot.ok)
        let has = await vault.has("gone"); XCTAssertFalse(has)
        let read = await vault.readSlot("gone", slot: "keychain:Claude Code"); XCTAssertNil(read)
        // Decrypt the file by hand: the deleted account's values are not in it at all.
        let text = try String(contentsOf: vault.file, encoding: .utf8)
        let plain = try BackendF4FakeCipher.decrypt(try XCTUnwrap(Data(base64Encoded: text)))
        XCTAssertFalse(plain.contains("GONE")); XCTAssertTrue(plain.contains("KEPT"))
        await vault.close()
    } }

    // store.test.ts:107
    func testDropRemovesOneSlotAndTheAccountWithItWhenNothingIsLeft() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f)
        _ = await vault.write(accountID: "a", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("A"), source: "sign-in")
        _ = await vault.dropSlot("a", slot: credentials)
        let has = await vault.has("a"); XCTAssertFalse(has)
        let summary = await vault.summary("a"); XCTAssertNil(summary)
        await vault.close()
    } }

    // store.test.ts:115
    func testRefusesToSaveAnythingWhenThereIsNoSecureStoreAndWritesNoFile() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f, cipher: BackendF4FakeCipher(available: false))
        let result = await vault.write(accountID: "a", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("A"), source: "sign-in")
        XCTAssertFalse(result.ok); XCTAssertEqual(result.message, BackendAccountVault.noSecureStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.file.path))
        await vault.close()
    } }

    // store.test.ts:131
    func testLeavesAVaultThatWillNotDecryptExactlyAsItIsRefusesWritesAndTriesAgain() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vaultDirectory = f.configuration.dataDirectory.appendingPathComponent(BackendAccountVault.directoryName)
        try FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = vaultDirectory.appendingPathComponent(BackendAccountVault.fileName)
        let original = Data("a vault from another build of the app".utf8).base64EncodedString()
        try original.write(to: file, atomically: true, encoding: .utf8)
        let vault = try BackendF4Vault(f, now: { 42 })
        let summaries = await vault.allSummaries(); XCTAssertEqual(summaries, [])
        let write = await vault.write(accountID: "a", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("A"), source: "sign-in")
        XCTAssertFalse(write.ok)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".unreadable-42"))
        XCTAssertEqual(write.message, BackendAccountVault.locked)
        let state = await vault.state(); XCTAssertEqual(state, .locked)
        await vault.close()
        // Not cached: once the key is back, the same vault opens.
        let counting = BackendF4FakeCipher()
        let watched = try BackendF4Vault(f, cipher: counting)
        let first = await watched.openState(), second = await watched.openState()
        XCTAssertEqual(first, .locked); XCTAssertEqual(second, .locked)
        XCTAssertEqual(counting.decrypts, 2)
        await watched.close()
    } }

    // store.test.ts:154
    func testSetsAsideAVaultThatDecryptsButWillNotParseInsteadOfOverwritingIt() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vaultDirectory = f.configuration.dataDirectory.appendingPathComponent(BackendAccountVault.directoryName)
        try FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = vaultDirectory.appendingPathComponent(BackendAccountVault.fileName)
        try BackendF4FakeCipher.encrypt("{ this is not json").base64EncodedString().write(to: file, atomically: true, encoding: .utf8)
        let vault = try BackendF4Vault(f, now: { 42 })
        let opened = await vault.openState(); XCTAssertEqual(opened, .ready)
        let summaries = await vault.allSummaries(); XCTAssertEqual(summaries, [])
        _ = await vault.write(accountID: "a", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("A"), source: "sign-in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".unreadable-42"))
        await vault.close()
        let again = try BackendF4Vault(f)
        let has = await again.has("a"); XCTAssertTrue(has)
        await again.close()
    } }

    // store.test.ts:164
    func testReportsAnEncryptionFailureAsAFailedSave() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f, cipher: BackendF4FakeCipher(encryptFailure: "keychain said no"))
        let write = await vault.write(accountID: "a", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("A"), source: "sign-in")
        XCTAssertFalse(write.ok); XCTAssertTrue(write.message.contains("keychain said no"), write.message)
        await vault.close()
    } }

    // store.test.ts:179
    func testForgetsAnAccountInMemoryEvenWhenTheDiskRefusesAndSaysTheSaveFailed() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let fail = BackendF4Box(false)
        let vault = try BackendF4Vault(f, writeFile: { data, file in
            if fail.value { throw BackendAccountFailure("disk full") }
            try data.write(to: file)
        })
        _ = await vault.write(accountID: "gone", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("GONE"), source: "sign-in")
        fail.value = true
        let result = await vault.forgetAccount("gone")
        XCTAssertFalse(result.ok); XCTAssertTrue(result.message.contains("disk full"), result.message)
        let has = await vault.has("gone"); XCTAssertFalse(has)
        let read = await vault.readSlot("gone", slot: credentials); XCTAssertNil(read)
        await vault.close()
    } }

    // store.test.ts:206
    func testASummaryNamesSlotsTimesAndThePlanNeverAValue() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f)
        _ = await vault.write(accountID: "a", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("SECRET-VALUE", plan: "pro"), source: "sign-in")
        let summary = await vault.summary("a")
        XCTAssertEqual(summary?.plan, "pro"); XCTAssertEqual(summary?.slots, [credentials])
        let json = String(decoding: try JSONEncoder().encode(await vault.allSummaries()), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET-VALUE")); XCTAssertFalse(json.contains("sk-ant"))
        await vault.close()
    } }

    // store.test.ts:216
    func testTellsListenersWhichAccountChangedAndNothingAboutWhatItChangedTo() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let vault = try BackendF4Vault(f)
        let heard = BackendF4Box<[String]>([])
        await vault.onChange { id in heard.update { $0.append(id) } }
        _ = await vault.write(accountID: "a", provider: "claude", slot: credentials, value: BackendF4ClaudeLogin("A"), source: "sign-in")
        _ = await vault.forgetAccount("a")
        XCTAssertEqual(heard.value, ["a", "a"])
        await vault.close()
    } }
}
