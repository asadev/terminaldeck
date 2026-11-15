import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class CloudSecretsFixtureAPICredentials: BackendCloudSecretsAPICredentials, @unchecked Sendable {
    let lock = NSLock()
    var values: [String: String] = [:]
    var reads = 0, writes = 0
    func read(_ record: BackendAPIAccountRecord) -> String? { lock.withLock { reads += 1; return values[record.accountID] } }
    func replace(_ key: String, record: BackendAPIAccountRecord) { lock.withLock { values[record.accountID] = key } }
    func addAbsent(_ key: String, record: BackendAPIAccountRecord) throws {
        try lock.withLock { guard values[record.accountID] == nil else { throw CloudFailure.idReused }; values[record.accountID] = key; writes += 1 }
    }
}
private actor CloudSecretsFixtureCount {
    var stages: [CloudSecretsStage: Int] = [:]
    func called(_ stage: CloudSecretsStage) { stages[stage, default: 0] += 1 }
    func total() -> Int { stages.values.reduce(0, +) }
}
private actor CloudSecretsFixtureSlots: CloudSecretsLogicalStore {
    nonisolated let sourceId = "fixture-subscription"
    nonisolated let inventoryRow = "I13"
    nonisolated let domain = CloudSecretsDomain.aiSubscription
    var calls = 0
    func capture() -> [CloudSecretRecord] { calls += 1; return [] }
    func validate(_ record: CloudSecretRecord) { calls += 1 }
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus { calls += 1; return .applied }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool { calls += 1; return true }
}
@MainActor
final class CloudSecretsAdapterTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudSecretsAdapterTests assertions=\(assertions)") }
    func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) { assertions += 1; XCTAssertTrue(condition, "Adapter assertion", file: file, line: line) }
    func api(_ endpoint: String = "https://api.openai.com/v1") throws -> BackendAPIAccountRecord {
        try .init(profile: .init(id: "api-key-111111111111111111111111", name: "Fixture API", provider: "codex",
            configDir: "/fixture/account-logins/api-one", system: false, color: "--accent", createdAt: 0), appName: "Fixture",
            kind: .compatible, baseURL: endpoint, model: "fixture")
    }
    func testS19SubscriptionOffHasZeroCallsAtAllSixBoundaries() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        let count = CloudSecretsFixtureCount(), fence = CloudSecretsSubscriptionFence(policy: client.policy)
        for stage in CloudSecretsStage.allCases {
            do { try await fence.perform(stage) { await count.called(stage) }; check(false) } catch { check(true) }
        }
        check(await count.total() == 0)
        for (provider, slot) in [("claude", "keychain:Claude Code-credentials"), ("codex", "file:auth.json"), ("gemini", "file:oauth_creds.json")] {
            check(try BackendCloudSecretsSubscriptionSlots.classify(provider: provider, slot: slot) == .aiSubscription)
            for stage in CloudSecretsStage.allCases {
                do { try await BackendCloudSecretsSubscriptionSlots.perform(provider: provider, slot: slot, stage: stage, policy: client.policy) { await count.called(stage) }; check(false) }
                catch { check(true) }
            }
        }
        check(await count.total() == 0)
        let slots = CloudSecretsFixtureSlots()
        let journal = CloudSecretsFixtureJournal()
        let adapter = CloudSecretsLogicalAdapter(store: slots, content: client.content, policy: client.policy, deviceId: client.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        do { _ = try await adapter.exportRecords(); check(false) } catch { check(true) }
        do { _ = try await adapter.sourceInventory(); check(false) } catch { check(true) }
        do { _ = try await adapter.snapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 0, watermarks: [:])); check(false) } catch { check(true) }
        do { _ = try await adapter.validateIncoming([], files: []); check(false) } catch { check(true) }
        do { _ = try await client.content.seal(Data(), blobId: UUID().uuidString.lowercased(), storageClass: .secrets, purpose: .aiSubscription, epoch: 1, codec: .identity); check(false) } catch { check(true) }
        let envelope = CloudContentEnvelope(v: 1, suite: "A256GCM-HKDF-SHA256", storageClass: .secrets, purpose: .aiSubscription,
            epoch: 1, blobId: UUID().uuidString.lowercased(), codec: .identity, plainBytes: 0, nonce: "", ciphertext: "", tag: "")
        do { _ = try await client.content.open(envelope); check(false) } catch { check(true) }
        check(await slots.calls == 0)
        for path in ["auth.json", ".credentials.json", "oauth_creds.json", ".gemini/oauth_tokens.json", "keychain:Claude Code-credentials"] {
            check(CloudSecretsPolicy.classify(relativePath: path, sourceId: "backup").purpose == .aiSubscription)
        }
        check(CloudSecretsPolicy.classify(relativePath: ".env.local", sourceId: "backup").storageClass == .secrets)
        check(CloudSecretsPolicy.classify(relativePath: "src/main.swift", sourceId: "backup").storageClass == .brain)
    }
    func testAPIEndpointBindingAddOnlyAndDisguisedRecords() async throws {
        let record = try api(), sourceCredentials = CloudSecretsFixtureAPICredentials(), targetCredentials = CloudSecretsFixtureAPICredentials()
        try sourceCredentials.addAbsent("fixture-api-value-001", record: record)
        let source = BackendCloudSecretsAPIStore(sourceId: "api", records: { [record] }, credentials: sourceCredentials)
        let target = BackendCloudSecretsAPIStore(sourceId: "api", records: { [record] }, credentials: targetCredentials)
        let rows = try await source.capture()
        check(rows.count == 1)
        check(try await target.merge(rows[0]) == .applied)
        check(try await target.verify(rows[0], outcome: .applied))
        check(try await target.merge(rows[0]) == .alreadyPresent)
        check(targetCredentials.writes == 1)
        let other = try api("https://example.invalid/v1")
        let mismatched = BackendCloudSecretsAPIStore(sourceId: "api", records: { [other] }, credentials: targetCredentials)
        check(try await mismatched.merge(rows[0]) == .keptBoth)
        check(targetCredentials.writes == 1)
        let disguised = CloudSecretRecord(sourceId: "api", recordId: record.accountID, domain: "api-key",
            payload: .init(rows[0].payload.raw.setting("auth.json", .string("fixture-subscription"))))
        do { try await target.validate(disguised); check(false) } catch { check(true) }
        check(targetCredentials.writes == 1)
    }
    func testServerWriterKeepsPasswordAndSSHKeyConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-secrets-" + UUID().uuidString.lowercased()).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cipher = BackendBrowserPasswordsCipher(available: { true }, decrypt: { String(decoding: $0, as: UTF8.self) }, encrypt: { text, _ in Data(text.utf8) })
        let store = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: .init(validate: { _, _ in nil }))
        let adapter = BackendCloudSecretsServerStore(sourceId: "servers", store: store, serverExists: { _ in true })
        let password = try BackendCloudSecretsRecords.record("servers", "one", .server, BackendCloudSecretsServerValue(credential: .password("fixture-password")))
        let key = try BackendCloudSecretsRecords.record("servers", "two", .server, BackendCloudSecretsServerValue(credential: .key(privateKey: "fixture-private-key", passphrase: "fixture-passphrase")))
        check(try await adapter.merge(password) == .applied)
        check(try await adapter.merge(key) == .applied)
        check(try await adapter.capture().count == 2)
        store.close()
        check(try await adapter.verify(key, outcome: .applied))
        let original = try Data(contentsOf: store.file)
        let changed = try BackendCloudSecretsRecords.record("servers", "one", .server, BackendCloudSecretsServerValue(credential: .password("different-fixture-password")))
        check(try await adapter.merge(changed) == .keptBoth)
        check(try Data(contentsOf: store.file) == original)
        store.holdForSession("three", credential: .password("session-only-fixture"))
        check(try await adapter.capture().count == 2)
        _ = try store.save("alias", credential: .sshConfig(alias: "fixture-alias"))
        check(try await adapter.capture().count == 2)
    }
    func testSetupQueuesTheExistingBaselineOnlyAfterConfirmedReadback() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        let record = try api(), credentials = CloudSecretsFixtureAPICredentials(), outbox = CloudSecretsFixtureOutbox()
        try credentials.addAbsent("fixture-baseline-api-key", record: record)
        let adapter = CloudSecretsLogicalAdapter(store: BackendCloudSecretsAPIStore(sourceId: "api", records: { [record] }, credentials: credentials),
            content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content, outbox: outbox, adapters: [adapter], prepareSynchronization: { await outbox.prepareSynchronization() }, restoreLocalStores: {})
        await client.ui.setConfirmation(false)
        do { try await service.beginSetup(); check(false) } catch { check(true) }
        check(await outbox.queued.isEmpty)
        check(credentials.reads == 0)
        check(await outbox.preparations == 0)
        await client.ui.setConfirmation(true)
        try await service.beginSetup()
        check(try await service.status().recoveryReady)
        let queued = await outbox.queued
        check(queued.count == 1)
        check(try CloudSecretsCanonical.encode(queued).range(of: Data("fixture-baseline-api-key".utf8)) == nil)
        check(await outbox.pulls == 1)
        check(await outbox.flushes == 1)
        check(await outbox.preparations == 1)
        _ = try await service.captureChanged(sourceId: "api")
        check(await outbox.queued.count == 1)
    }
    func testImportedValuesDoNotEchoButNewLocalEditsAreQueued() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let record = try api(), credentials = CloudSecretsFixtureAPICredentials(), journal = CloudSecretsFixtureJournal()
        let store = BackendCloudSecretsAPIStore(sourceId: "api", records: { [record] }, credentials: credentials)
        let adapter = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy,
            deviceId: client.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        let incoming = try BackendCloudSecretsRecords.record("api", record.accountID, .apiKey,
            BackendCloudSecretsAPIValue(record: record, key: "fixture-incoming-key"))
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:])
        let encrypted = try await adapter.snapshot(records: [incoming], cut: cut)
        let prepared = try await adapter.validateIncoming(encrypted.operations, files: [])
        _ = try await adapter.applyPrepared(prepared, origin: .init(deviceId: client.device.deviceId, sequence: CloudSequence(1)))
        check(try await adapter.changedSnapshot(cut: cut).operations.isEmpty)
        credentials.replace("fixture-local-new-key", record: record)
        let changed = try await adapter.changedSnapshot(cut: cut)
        check(changed.operations.count == 1)
        let receipt = try await journal.enqueue(changed.operations)
        try await adapter.markPublished(changed, receipt: receipt)
        check(try await adapter.changedSnapshot(cut: cut).operations.isEmpty)
        check(await journal.operations.count == 1)
        try await client.coordinator.reset()
        check(try await adapter.changedSnapshot(cut: cut).operations.count == 1)
    }
    func testCiphertextOnlyLogicalTransferRejectsTamperBeforeWriter() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let record = try api(), sourceCredentials = CloudSecretsFixtureAPICredentials(), targetCredentials = CloudSecretsFixtureAPICredentials()
        try sourceCredentials.addAbsent("fixture-api-value-001", record: record)
        let journal = CloudSecretsFixtureJournal()
        let source = CloudSecretsLogicalAdapter(store: BackendCloudSecretsAPIStore(sourceId: "api", records: { [record] }, credentials: sourceCredentials),
            content: client.content, policy: client.policy, deviceId: client.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        let target = CloudSecretsLogicalAdapter(store: BackendCloudSecretsAPIStore(sourceId: "api", records: { [record] }, credentials: targetCredentials),
            content: client.content, policy: client.policy, deviceId: client.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        let snapshot = try await source.snapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:]))
        let bytes = try CloudSecretsCanonical.encode(snapshot)
        check(bytes.range(of: Data("fixture-api-value-001".utf8)) == nil)
        let prepared = try await target.validateIncoming(snapshot.operations, files: [])
        check(targetCredentials.writes == 0)
        let receipt = try await target.applyPrepared(prepared, origin: .init(deviceId: client.device.deviceId, sequence: CloudSequence(1)))
        check(receipt.counts.records == 1)
        check(try await target.verify(receipt).verified)
        check(targetCredentials.writes == 1)
        let raw = try NativeRPCValue.parseJSON(JSONEncoder().encode(snapshot.operations[0]))
        let broken = try JSONDecoder().decode(CloudOperation.self, from: raw.setting("payloadHash", .string("bad")).encodedJSON())
        do { _ = try await target.validateIncoming([broken], files: []); check(false) } catch { check(true) }
        check(targetCredentials.writes == 1)
        await client.gate.disableCloud()
        do { _ = try await source.exportRecords(); check(false) } catch { check(true) }
    }
}
