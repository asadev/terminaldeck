import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Blocker 2 of the lean first version: the hosted app holds no account vault (the session host helper is its one
/// writer), so saved passwords must work without one, and a Mac whose own store key is gone is told the truth and
/// never switched to an empty store. Fixture bytes only; no Security calls; folders only under
/// ~/Deck Dev/notes/cloud-test-20261112/v/.
private struct CloudLeanFixtureCipher: BackendAccountVaultCipher {
    let password: Data
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func decrypt(_ blob: Data) throws -> String { try ChromiumSafeStorageCipher.decrypt(blob, password: password) }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { try ChromiumSafeStorageCipher.encrypt(text, password: password) }
    var forStores: BackendBrowserPasswordsCipher {
        let cipher = self
        return .init(available: { true }, decrypt: { try cipher.decrypt($0) }, encrypt: { try cipher.encrypt($0, existingVault: $1) })
    }
}
private final class CloudLeanFixtureKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var original: BackendCloudRecoveryKeyState
    private var generations: [String: Data] = [:]
    private var made = 0
    init(_ original: BackendCloudRecoveryKeyState) { self.original = original }
    var creations: Int { lock.withLock { made } }
    func owner() -> BackendCloudRecoveryLocalKeyOwner {
        .init(originalKey: { self.lock.withLock { self.original } },
              generationKey: { id in self.lock.withLock { self.generations[id] == nil ? .missing : .present } },
              create: { id in
                  let key = try CloudSecretsCrypto.random(32)
                  self.lock.withLock { self.generations[id] = key; self.made += 1 }
              },
              cipher: { id in
                  try self.lock.withLock {
                      guard let value = self.generations[id] else { throw CloudFailure.secretsLocked }
                      return CloudLeanFixtureCipher(password: value)
                  }
              })
    }
}
/// One fixture "Mac": its own folder, server list and credentials owner, as the Servers feature builds them.
private struct CloudRecoveryLeanFixtureMac {
    let root: URL
    let configuration: BackendAccountConfiguration
    let list: BackendServersStore
    let credentials: BackendServersCredentials
    let port: BackendCloudSecretsServerPort
    init(_ name: String, in folder: URL, cipher: CloudLeanFixtureCipher) throws {
        root = folder.appendingPathComponent(name, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true), home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Terminal Deck Fixture",
            appID: "terminaldeck", helperExecutable: root.appendingPathComponent("never-run-helper"), inheritedEnvironment: [:])
        let policy = BackendServersStoragePolicy(mayRead: true, mayWrite: true)
        list = BackendServersStore(dataRoot: data, policy: policy, serverAccessEnabled: true)
        credentials = BackendServersCredentials(dataRoot: data, cipher: cipher.forStores, policy: policy, keyValidator: .init(validate: { _, _ in nil }))
        port = BackendCloudSecretsServerPort(sourceId: "servers", credentials: credentials, servers: list)
    }
    var names: Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: configuration.dataDirectory.path)) ?? []) }
}

@MainActor
final class CloudRecoveryLeanLocalStoresTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudRecoveryLeanLocalStoresTests assertions=\(assertions)") }
    func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(value, "Lean local stores assertion", file: file, line: line)
    }
    private func folder() throws -> URL {
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/v")
        let made = approved.appendingPathComponent("lean-stores-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }
    private func adapter(_ mac: CloudRecoveryLeanFixtureMac, _ client: CloudSecretsFixtureClient, _ journal: CloudSecretsFixtureJournal) -> CloudSecretsLogicalAdapter {
        CloudSecretsLogicalAdapter(store: mac.port.store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
    }

    /// With no account vault at all: setup with words on one Mac, then the second Mac is unlocked by the two codes
    /// or by the words, and a saved server sign-in arrives. No new key, no route, no store switch.
    func testWithoutAnAccountVaultSetupApprovalWordsAndSyncAllWork() async throws {
        for useWords in [false, true] {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let macA = try CloudRecoveryLeanFixtureMac("a", in: folder, cipher: .init(password: Data(repeating: 11, count: 32)))
            let macB = try CloudRecoveryLeanFixtureMac("b", in: folder, cipher: .init(password: Data(repeating: 12, count: 32)))
            let server = try macA.list.add(.init(name: "Fixture box", address: "box.fixture.invalid", username: "deploy"))
            check(try macA.credentials.save(server.id, credential: .password("fixture-server-value")).ok)
            let remote = CloudSecretsFixtureServer()
            let author = try await CloudSecretsFixtureClient(server: remote), target = try await CloudSecretsFixtureClient(server: remote)
            try await author.coordinator.setup()
            let journal = CloudSecretsFixtureJournal()
            let sent = try await adapter(macA, author, journal).snapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 0, watermarks: [:]))
            check(sent.operations.count == 1)
            let keys = CloudLeanFixtureKeys(.present)
            let migration = BackendCloudRecoveryLocalStores.lean(configuration: macB.configuration, keys: keys.owner(), policy: target.policy,
                servers: macB.port, voice: nil, requireWriter: {})
            let standingBefore = await migration.standing()
            check(standingBefore == .ready)
            let receiving = adapter(macB, target, journal), outbox = CloudSecretsFixtureOutbox()
            let operations = sent.operations, authorId = author.device.deviceId
            await outbox.onPull {
                let preparation = try await receiving.validateIncoming(operations, files: [])
                _ = try await receiving.applyPrepared(preparation, origin: .init(deviceId: authorId, sequence: CloudSequence(1)))
            }
            let service = try CloudSecretsService(recovery: target.coordinator, policy: target.policy, content: target.content,
                outbox: outbox, adapters: [receiving], prepareSynchronization: {},
                restoreLocalStores: { try await migration.recoverAfterVerifiedCloudUnlock() })
            if useWords {
                await target.ui.setWords(await author.ui.phrase)
                try await service.beginRecovery()
            } else {
                let pending = try await service.requestApproval()
                try await author.coordinator.approve(id: pending.approvalId)
                try await service.receiveApproval()
            }
            check(try await service.status().recoveryReady)
            check(try macB.credentials.read(server.id) == .password("fixture-server-value"))
            check(try macB.list.get(server.id)?.address == "box.fixture.invalid")
            // Nothing of the lost-key path ran: no new key, no route, no second store.
            check(keys.creations == 0)
            check(!macB.names.contains("cloud-local-stores"))
            try await migration.resume()
            check(try macB.credentials.read(server.id) == .password("fixture-server-value"))
        }
    }

    /// A Mac whose own store key is gone: the truth is told, the unlock itself still works, and nothing on the Mac
    /// is created, switched, emptied or uploaded.
    func testALostKeyIsToldTruthfullyAndNoStoreIsEverSwitchedOrEmptied() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = try CloudRecoveryLeanFixtureMac("lost", in: folder, cipher: .init(password: Data(repeating: 21, count: 32)))
        // Saved sign-ins sealed by a key that is no longer on this Mac.
        let gone = CloudLeanFixtureCipher(password: Data(repeating: 88, count: 32))
        let sealed = Data(try gone.encrypt("{\"version\":1,\"entries\":[]}", existingVault: true).base64EncodedString().utf8)
        try BackendAccountFiles.writeAtomic(sealed, to: mac.credentials.file)
        let namesBefore = mac.names
        let remote = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: remote), target = try await CloudSecretsFixtureClient(server: remote)
        try await author.coordinator.setup()
        let keys = CloudLeanFixtureKeys(.missing)
        let migration = BackendCloudRecoveryLocalStores.lean(configuration: mac.configuration, keys: keys.owner(), policy: target.policy,
            servers: mac.port, voice: nil, requireWriter: {})
        let standing = await migration.standing()
        check(standing == .keyLost(["server"]))
        check(!standing.offersAllowLoginStore)
        let journal = CloudSecretsFixtureJournal(), outbox = CloudSecretsFixtureOutbox()
        let service = try CloudSecretsService(recovery: target.coordinator, policy: target.policy, content: target.content,
            outbox: outbox, adapters: [adapter(mac, target, journal)], prepareSynchronization: {},
            restoreLocalStores: { try await migration.recoverAfterVerifiedCloudUnlock() })
        await target.ui.setWords(await author.ui.phrase)
        do { try await service.beginRecovery(); check(false) }
        catch let refusal as BackendCloudRecoveryKeyLost { check(refusal.owners == ["server"]) }
        // The Cloud key itself is on this Mac now (it can allow another Mac); its own stores are untouched.
        let protection = await service.protection()
        check(protection == .protected)
        let pulls = await outbox.pulls, queued = await outbox.queued.count, kept = await journal.operations.count
        check(pulls == 0)
        check(queued == 0)
        check(kept == 0)
        check(keys.creations == 0)
        check(mac.names == namesBefore)
        check(try Data(contentsOf: mac.credentials.file) == sealed)
        let after = await migration.standing()
        check(after == .keyLost(["server"]))
        try await migration.resume()
        check(mac.names == namesBefore)
        // The words: locked on this Mac, nothing changed, and no promise this version cannot keep.
        let unlocked = try XCTUnwrap(standing.words(cloudKeyHere: true)), locked = try XCTUnwrap(standing.words(cloudKeyHere: false))
        for words in [unlocked, locked] {
            check(words.contains("locked on this Mac"))
            check(words.contains("Nothing on this Mac was changed or deleted"))
            check(words.contains("cannot bring them back onto this Mac yet"))
            check(!words.contains("Allow login store"))
        }
        check(locked.contains("recovery words or from another device"))
        check(!unlocked.contains("from another device"))
    }

    /// A key that exists but is blocked stops with "Allow login store" and changes nothing; a new Mac with no key
    /// and nothing saved yet is simply ready.
    func testABlockedKeyAsksForTheLoginStoreAndAFreshMacIsReady() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now)
        let policy = CloudSecretsPolicy(capabilities: { await gate.value() }, now: { CloudSecretsFixtureServer.now })
        let blockedMac = try CloudRecoveryLeanFixtureMac("blocked", in: folder, cipher: .init(password: Data(repeating: 31, count: 32)))
        let blockedKeys = CloudLeanFixtureKeys(.blocked("fixture: keychain locked"))
        let blocked = BackendCloudRecoveryLocalStores.lean(configuration: blockedMac.configuration, keys: blockedKeys.owner(), policy: policy,
            servers: blockedMac.port, voice: nil, requireWriter: {})
        let standing = await blocked.standing()
        check(standing == .blocked("fixture: keychain locked"))
        check(standing.offersAllowLoginStore)
        check(standing.words(cloudKeyHere: false)?.contains("Allow login store") == true)
        do { try await blocked.recoverAfterVerifiedCloudUnlock(); check(false) }
        catch is BackendCloudRecoveryBlocked { check(true) }
        check(blockedKeys.creations == 0)
        check(!blockedMac.names.contains("cloud-local-stores"))
        let freshMac = try CloudRecoveryLeanFixtureMac("fresh", in: folder, cipher: .init(password: Data(repeating: 32, count: 32)))
        let freshKeys = CloudLeanFixtureKeys(.missing)
        let fresh = BackendCloudRecoveryLocalStores.lean(configuration: freshMac.configuration, keys: freshKeys.owner(), policy: policy,
            servers: freshMac.port, voice: nil, requireWriter: {})
        let freshStanding = await fresh.standing()
        check(freshStanding == .ready)
        check(freshStanding.words(cloudKeyHere: false) == nil)
        try await fresh.recoverAfterVerifiedCloudUnlock()
        check(freshKeys.creations == 0)
        check(!freshMac.names.contains("cloud-local-stores"))
    }

    /// The full lost-key path (kept for a later version) moves only owners it was handed: with no account vault,
    /// no browser store and no Receiver, a route never names them, even while AI subscriptions are switched on.
    func testOnlyOwnersHandedInAreEverMovedAndNeverTheAccountVault() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = try CloudRecoveryLeanFixtureMac("full", in: folder, cipher: .init(password: Data(repeating: 21, count: 32)))
        let gone = CloudLeanFixtureCipher(password: Data(repeating: 88, count: 32))
        let sealed = Data(try gone.encrypt("{\"version\":1,\"entries\":[]}", existingVault: true).base64EncodedString().utf8)
        try BackendAccountFiles.writeAtomic(sealed, to: mac.credentials.file)
        let aiOn = CloudSecretsPolicy(capabilities: {
            CloudGate(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: true, expiresAt: CloudSecretsFixtureServer.now + 300_000)
        }, now: { CloudSecretsFixtureServer.now })
        let keys = CloudLeanFixtureKeys(.missing)
        let migration = BackendCloudRecoveryLocalStores(configuration: mac.configuration, keys: keys.owner(), policy: aiOn,
            vault: nil, passwords: nil, servers: mac.credentials, voice: nil, receiver: nil,
            requireReceiverInert: { throw CloudFailure.unavailable }, requireWriter: {})
        try await migration.recoverAfterVerifiedCloudUnlock()
        check(keys.creations == 1)
        let route = try NativeRPCValue.parseJSON(Data(contentsOf: mac.configuration.dataDirectory.appendingPathComponent("cloud-local-stores/current.json")))
        check(route["owners"].elements?.compactMap(\.string) == ["server"])
        check(!mac.names.contains("account-vault"))
        // The original file is still there, byte for byte; new values go to the new store.
        check(try Data(contentsOf: mac.credentials.file) == sealed)
        check(try mac.credentials.save("fixture-server", credential: .password("fixture-new-value")).ok)
        check(try Data(contentsOf: mac.credentials.file) == sealed)
        check(try mac.credentials.read("fixture-server") == .password("fixture-new-value"))
    }
}
