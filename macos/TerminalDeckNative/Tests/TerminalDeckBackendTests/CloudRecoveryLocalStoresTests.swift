import XCTest
import Security
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Only fixture bytes and temporary files; no Security calls or provider homes.
private struct CloudRecoveryFixtureLocalCipher: BackendAccountVaultCipher, BackendOSVoiceEncrypting {
    let password: Data
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func decrypt(_ blob: Data) throws -> String { try ChromiumSafeStorageCipher.decrypt(blob, password: password) }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { try ChromiumSafeStorageCipher.encrypt(text, password: password) }
}
private final class CloudRecoveryFixtureVaultAccess: BackendAccountVaultCipher, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let base: CloudRecoveryFixtureLocalCipher
    init(_ base: CloudRecoveryFixtureLocalCipher) { self.base = base }
    var calls: Int { lock.withLock { count } }
    private func called() { lock.withLock { count += 1 } }
    func available() -> Bool { called(); return base.available() }
    func prepareForWrites(existingVault: Bool) throws { called(); try base.prepareForWrites(existingVault: existingVault) }
    func decrypt(_ blob: Data) throws -> String { called(); return try base.decrypt(blob) }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { called(); return try base.encrypt(text, existingVault: existingVault) }
}
private final class CloudRecoveryFixtureLocalKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private(set) var creations = 0
    private var blocked: String?
    func forgetAll() { lock.withLock { values = [:] } }
    /// A key that exists but cannot be opened now (locked, denied, refused).
    func block(_ reason: String?) { lock.withLock { blocked = reason } }
    func owner() -> BackendCloudRecoveryLocalKeyOwner {
        .init(originalKey: { self.lock.withLock { self.blocked.map { .blocked($0) } ?? .missing } },
              generationKey: { id in self.lock.withLock {
                  if let reason = self.blocked { return .blocked(reason) }
                  return self.values[id] == nil ? .missing : .present
              } },
              create: { id in
            let key = try CloudSecretsCrypto.random(32)
            self.lock.withLock { self.values[id] = key; self.creations += 1 }
        },
              cipher: { id in try self.lock.withLock {
                  guard let value = self.values[id] else { throw CloudFailure.secretsLocked }
                  return CloudRecoveryFixtureLocalCipher(password: value)
              } })
    }
}
@MainActor
final class CloudRecoveryLocalStoresTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudRecoveryLocalStoresTests assertions=\(assertions)") }
    func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(value, "Local recovery assertion", file: file, line: line)
    }
    func testS09KeychainLossPreservesRosterAndOriginalStoresWordsAndApprovalRehydrate() async throws {
        for (useWords, hadPasswordFiles) in [(true, true), (false, true), (true, false), (false, false)] {
            let fixture = try BackendFoundationTestsAccountsFixture()
            do {
                let profile = try await fixture.create("Surviving card")
                let rosterBefore = try Data(contentsOf: fixture.configuration.dataDirectory.appendingPathComponent("profiles.json"))
                let lostCipher = CloudRecoveryFixtureLocalCipher(password: Data(repeating: 21, count: 32))
                let subscriptionAccess = CloudRecoveryFixtureVaultAccess(lostCipher)
                let vault = try BackendAccountVault(configuration: fixture.configuration, stateStore: fixture.state, vaultCipher: subscriptionAccess)
                let browserCipher = BackendBrowserPasswordsCipher(available: { true }, decrypt: { try lostCipher.decrypt($0) }, encrypt: { try lostCipher.encrypt($0, existingVault: $1) })
                let passwords = try BackendBrowserPasswords(dataRoot: fixture.configuration.dataDirectory, cipher: browserCipher,
                    host: .init(tab: { _ in nil }, fill: { _, _, _ in false }, copy: { _ in }, reveal: { _ in }), requireWriter: {}, requireProfile: { _ in })
                let servers = BackendServersCredentials(dataRoot: fixture.configuration.dataDirectory, cipher: browserCipher,
                    policy: .init(mayRead: true, mayWrite: true), keyValidator: .init(validate: { _, _ in nil }))
                let voice = try BackendOSVoiceService(userData: fixture.configuration.dataDirectory, store: fixture.state, cipher: lostCipher, authorize: { _, _ in })
                try await voice.activate()
                let receiverPersistence = try BackendTaskPersistence(directory: fixture.configuration.dataDirectory.appendingPathComponent("remote"), ownership: .exclusive)
                let receiver = BackendRCVStore(persistence: receiverPersistence, cipher: lostCipher, saveDelayMilliseconds: 0)
                // Real legacy ciphertext, sealed by a key no longer on this Mac.
                let oldCipher = CloudRecoveryFixtureLocalCipher(password: Data(repeating: 88, count: 32))
                let empty = "{\"version\":1,\"entries\":[]}"
                var originals: [URL: Data] = [:]
                for file in hadPasswordFiles ? [vault.file, passwords.file, servers.file] : [vault.file] {
                    originals[file] = Data(try oldCipher.encrypt(empty, existingVault: true).base64EncodedString().utf8)
                }
                if hadPasswordFiles {
                    originals[voice.file] = try oldCipher.encrypt(BackendOSVoiceRules.encodeKey(provider: "groq", key: "fixture-previous-voice"), existingVault: true)
                }
                let receiverOld = BackendRCVState(receiverKey: Data(repeating: 19, count: 32))
                let receiverBlob = try oldCipher.encrypt(String(decoding: JSONEncoder().encode(receiverOld), as: UTF8.self), existingVault: true)
                if hadPasswordFiles {
                    originals[try receiverPersistence.file(BackendRCVStore.fileName)] = try NativeRPCValue.object([
                        .init("version", .number(1)), .init("encrypted", .string(receiverBlob.base64EncodedString()))]).encodedJSON()
                }
                for (file, bytes) in originals { try BackendAccountFiles.writeAtomic(bytes, to: file) }
                check(await vault.openState() == .locked)
                check(try await fixture.profiles.list().contains { $0.id == profile.id })
                let localKeys = CloudRecoveryFixtureLocalKeys()
                let remote = CloudSecretsFixtureServer()
                let author = try await CloudSecretsFixtureClient(server: remote), target = try await CloudSecretsFixtureClient(server: remote)
                let migration = BackendCloudRecoveryLocalStores(configuration: fixture.configuration, keys: localKeys.owner(), policy: target.policy,
                    vault: vault, passwords: passwords, servers: servers, voice: voice, receiver: receiver, requireReceiverInert: {}, requireWriter: {})
                try await author.coordinator.setup()
                let outbox = CloudSecretsFixtureOutbox()
                let store = BackendCloudSecretsServerStore(sourceId: "recovered-servers", store: servers, serverExists: { _ in true })
                let browser = BackendCloudBrowserPasswordStore(sourceId: "recovered-browser", profileId: "default", store: passwords)
                let appVoice = BackendCloudSecretsVoiceStore(sourceId: "recovered-voice", owner: voice)
                let receiverStore = BackendCloudSecretsReceiverStore(sourceId: "recovered-receiver", store: receiver, requireInert: {})
                let password = BackendCloudBrowserPassword(profileId: "default", origin: "https://fixture.invalid", username: "fixture", password: "fixture-restored-password", updatedAt: 1)
                let provider = try XCTUnwrap(BackendOSVoiceRules.provider("groq"))
                let receiverValue = BackendCloudSecretsReceiverValue(receiverKey: Data(repeating: 29, count: 32), secrets: ["fixture": .init(secret: "fixture-restored-receiver")])
                let rows: [(any CloudSecretsLogicalStore, [CloudSecretRecord])] = [
                    (store, [try BackendCloudSecretsRecords.record("recovered-servers", "surviving-server", .server, BackendCloudSecretsServerValue(credential: .password("restored-fixture-value")))]),
                    (browser, [try BackendCloudSecretsRecords.record("recovered-browser", password.identity, .browserPassword, password)]),
                    (appVoice, [try BackendCloudSecretsRecords.record("recovered-voice", "voice", .app, BackendCloudSecretsVoiceValue(provider: provider.id, endpoint: provider.endpoint, key: "fixture-restored-voice"))]),
                    (receiverStore, [try BackendCloudSecretsRecords.record("recovered-receiver", "receiver", .receiver, receiverValue)])]
                let journal = CloudSecretsFixtureJournal()
                var transfers: [(CloudSecretsLogicalAdapter, [CloudOperation])] = []
                for (owner, records) in rows {
                    let adapter = CloudSecretsLogicalAdapter(store: owner, content: target.content, policy: target.policy,
                        deviceId: target.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
                    let sender = CloudSecretsLogicalAdapter(store: owner, content: author.content, policy: author.policy,
                        deviceId: author.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
                    let snapshot = try await sender.snapshot(records: records, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 0, watermarks: [:]))
                    transfers.append((adapter, snapshot.operations))
                }
                let authorId = author.device.deviceId, incoming = transfers
                await outbox.onPull {
                    for (adapter, operations) in incoming {
                        let preparation = try await adapter.validateIncoming(operations, files: [])
                        _ = try await adapter.applyPrepared(preparation, origin: .init(deviceId: authorId, sequence: CloudSequence(1)))
                    }
                }
                let subscriptionCallsBefore = subscriptionAccess.calls
                let service = try CloudSecretsService(recovery: target.coordinator, policy: target.policy, content: target.content,
                    outbox: outbox, adapters: transfers.map { $0.0 }, prepareSynchronization: {},
                    restoreLocalStores: { try await migration.recoverAfterVerifiedCloudUnlock() })
                if useWords {
                    await target.ui.setWords(await author.ui.phrase)
                    try await service.beginRecovery()
                } else {
                    let pending = try await service.requestApproval()
                    try await author.coordinator.approve(id: pending.approvalId)
                    try await service.receiveApproval()
                }
                check(localKeys.creations == 1)
                check(try await service.status().recoveryReady)
                check(subscriptionAccess.calls == subscriptionCallsBefore)
                check(await vault.openState() == .locked) // Subscription slots stay OFF.
                check(try await store.capture().count == 1)
                check(try servers.read("surviving-server") == .password("restored-fixture-value"))
                check(try await fixture.profiles.list().contains { $0.id == profile.id })
                check(try Data(contentsOf: fixture.configuration.dataDirectory.appendingPathComponent("profiles.json")) == rosterBefore)
                for (file, bytes) in originals { check(try Data(contentsOf: file) == bytes) }
                check(try await browser.capture().count == 1)
                check(try await appVoice.capture().count == 1)
                check(try await receiverStore.capture().count == 1)
                check(try await receiver.read().receiverKey == receiverValue.receiverKey)
                check(await outbox.queued.isEmpty)
                try await migration.resume()
                check(localKeys.creations == 1)
                check(try servers.read("surviving-server") == .password("restored-fixture-value"))
                check(try await browser.capture().count == 1)
                check(try await appVoice.capture().count == 1)
                check(try await receiverStore.capture().count == 1)
                // A second reset while owners still hold readable local values
                // must re-protect those values, not replace them with emptiness.
                localKeys.forgetAll()
                let callsBeforeSecondRecovery = subscriptionAccess.calls
                try await migration.recoverAfterVerifiedCloudUnlock()
                check(subscriptionAccess.calls == callsBeforeSecondRecovery)
                check(localKeys.creations == 2)
                try await migration.resume() // Reopen every file with the second generation key.
                check(try servers.read("surviving-server") == .password("restored-fixture-value"))
                check(try await browser.capture().count == 1)
                check(try await appVoice.capture().count == 1)
                check(try await receiverStore.capture().count == 1)
                for (file, bytes) in originals { check(try Data(contentsOf: file) == bytes) }
                await vault.close(); await passwords.close(); servers.close()
                await fixture.cleanup()
            } catch { await fixture.cleanup(); throw error }
        }
    }
    func testOnlyItemNotFoundCountsAsALostKey() {
        check(BackendCloudRecoveryKeyState.keychain(status: errSecItemNotFound, data: nil) == .missing)
        check(BackendCloudRecoveryKeyState.keychain(status: errSecSuccess, data: Data("k".utf8)) == .present)
        // Locked keychain, prompt not allowed, denied, cancelled, no keychain,
        // keychain unavailable, decode trouble, empty data: all blocked.
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoSuchKeychain,
                       errSecNotAvailable, errSecDecode, errSecMissingEntitlement, errSecParam, errSecInteractionRequired, OSStatus(-1)] {
            if case .blocked = BackendCloudRecoveryKeyState.keychain(status: status, data: nil) { check(true) } else { check(false) }
        }
        if case .blocked = BackendCloudRecoveryKeyState.keychain(status: errSecSuccess, data: Data()) { check(true) } else { check(false) }
        check(BackendCloudRecoveryKeyState.file { nil } == .missing)
        if case .blocked = BackendCloudRecoveryKeyState.file({ throw CloudFailure.unavailable }) { check(true) } else { check(false) }
    }
    func testBlockedNotLostLoginStoreKeyChangesNothing() async throws {
        let fixture = try BackendFoundationTestsAccountsFixture()
        do {
            let current = CloudRecoveryFixtureLocalCipher(password: Data(repeating: 21, count: 32))
            let vault = try BackendAccountVault(configuration: fixture.configuration, stateStore: fixture.state, vaultCipher: current)
            let browserCipher = BackendBrowserPasswordsCipher(available: { true }, decrypt: { try current.decrypt($0) }, encrypt: { try current.encrypt($0, existingVault: $1) })
            let passwords = try BackendBrowserPasswords(dataRoot: fixture.configuration.dataDirectory, cipher: browserCipher,
                host: .init(tab: { _ in nil }, fill: { _, _, _ in false }, copy: { _ in }, reveal: { _ in }), requireWriter: {}, requireProfile: { _ in })
            let servers = BackendServersCredentials(dataRoot: fixture.configuration.dataDirectory, cipher: browserCipher,
                policy: .init(mayRead: true, mayWrite: true), keyValidator: .init(validate: { _, _ in nil }))
            let voice = try BackendOSVoiceService(userData: fixture.configuration.dataDirectory, store: fixture.state, cipher: current, authorize: { _, _ in })
            try await voice.activate()
            let receiver = BackendRCVStore(persistence: try BackendTaskPersistence(directory: fixture.configuration.dataDirectory.appendingPathComponent("remote"), ownership: .exclusive),
                                           cipher: current, saveDelayMilliseconds: 0)
            // Saved values sealed by the key that is still there, only blocked now.
            let other = CloudRecoveryFixtureLocalCipher(password: Data(repeating: 88, count: 32))
            let saved = Data(try other.encrypt("{\"version\":1,\"entries\":[]}", existingVault: true).base64EncodedString().utf8)
            for file in [passwords.file, servers.file] { try BackendAccountFiles.writeAtomic(saved, to: file) }
            let before = try [passwords.file, servers.file].map { try Data(contentsOf: $0) }
            let keys = CloudRecoveryFixtureLocalKeys()
            let gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now)
            let policy = CloudSecretsPolicy(capabilities: { await gate.value() }, now: { CloudSecretsFixtureServer.now })
            let migration = BackendCloudRecoveryLocalStores(configuration: fixture.configuration, keys: keys.owner(), policy: policy,
                vault: vault, passwords: passwords, servers: servers, voice: voice, receiver: receiver, requireReceiverInert: {}, requireWriter: {})
            keys.block("fixture: keychain locked")
            do { try await migration.recoverAfterVerifiedCloudUnlock(); check(false) }
            catch is BackendCloudRecoveryBlocked { check(true) }
            check(keys.creations == 0)
            check(!FileManager.default.fileExists(atPath: fixture.configuration.dataDirectory.appendingPathComponent("cloud-local-stores").path))
            check(try [passwords.file, servers.file].map { try Data(contentsOf: $0) } == before)
            try await migration.resume() // no route: nothing switches at start either
            check(try [passwords.file, servers.file].map { try Data(contentsOf: $0) } == before)
            // Once allowed again, a truly missing key takes the normal path.
            keys.block(nil)
            try await migration.recoverAfterVerifiedCloudUnlock()
            check(keys.creations == 1)
            // A later blocked generation key also stops without a new generation.
            keys.block("fixture: permission denied")
            do { try await migration.recoverAfterVerifiedCloudUnlock(); check(false) }
            catch is BackendCloudRecoveryBlocked { check(true) }
            check(keys.creations == 1)
            await vault.close(); await passwords.close(); servers.close()
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }
    func testABlockedSecretsKeyTellsThePersonTheTrueStep() {
        let message = BackendCloudSecretsKeyBlocked(status: errSecInteractionNotAllowed).errorDescription ?? ""
        check(message.contains("sign out of Cloud on this Mac and sign in again"))
        check(message.contains("Nothing was deleted"))
        check(!message.contains("Allow login store"))
    }
}
