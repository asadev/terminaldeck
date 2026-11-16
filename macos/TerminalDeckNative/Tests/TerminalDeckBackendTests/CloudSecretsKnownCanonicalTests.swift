import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor CloudSecretsKnownFixtureStore: CloudSecretsLogicalStore {
    nonisolated let sourceId = "known-fixture"
    nonisolated let inventoryRow = "I13"
    nonisolated let domain = CloudSecretsDomain.app
    var values: [String: String] = ["one": "fixture-value-one", "two": "fixture-value-two"]
    func set(_ id: String, _ value: String) { values[id] = value }
    func capture() throws -> [CloudSecretRecord] {
        try values.keys.sorted().map { try BackendCloudSecretsRecords.record(sourceId, $0, domain, ["value": values[$0]!]) }
    }
    func validate(_ record: CloudSecretRecord) {}
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus { .applied }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool { true }
}

@MainActor
final class CloudSecretsKnownCanonicalTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudSecretsKnownCanonicalTests assertions=\(assertions)") }
    func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(value, "Known/canonical assertion", file: file, line: line)
    }
    func testRestartUploadsOnlyWhatChangedAndKeepsOnlyKeyedMarksOnDisk() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-known-" + UUID().uuidString.lowercased())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let known = BackendCloudSecretsKnown(dataRoot: root, requireWriter: {})
        let store = CloudSecretsKnownFixtureStore(), journal = CloudSecretsFixtureJournal()
        func adapter() -> CloudSecretsLogicalAdapter {
            .init(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
                  keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) }, known: known)
        }
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:])
        let first = adapter()
        await first.useOutbox(queue: "fixture-queue")
        let initial = try await first.changedSnapshot(cut: cut)
        check(initial.operations.count == 2)
        let receipt = try await journal.enqueue(initial.operations)
        try await first.markPublished(initial, receipt: receipt)
        await first.confirmed(operationIds: Set(initial.operations.map(\.opId))) // the cloud read them back
        // A new process: nothing in memory, the marks come from disk.
        let restarted = adapter()
        await restarted.useOutbox(queue: "fixture-queue")
        check(try await restarted.changedSnapshot(cut: cut).operations.isEmpty)
        await store.set("two", "fixture-value-two-changed")
        let changed = try await restarted.changedSnapshot(cut: cut)
        check(changed.operations.count == 1 && changed.operations.first?.entityId == "two")
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cloud-secret-known"), includingPropertiesForKeys: nil)
        check(files.count == 1)
        // The file name is keyed too: it does not confirm a guessed source name.
        check(files[0].lastPathComponent != CloudSecretsCrypto.hash(Data("known-fixture".utf8)) + ".json")
        let bytes = try Data(contentsOf: files[0])
        for needle in ["fixture-value-one", "fixture-value-two", "\"one\"", "\"two\"", "known-fixture"] {
            check(bytes.range(of: Data(needle.utf8)) == nil)
        }
        // An unkeyed hash of a record would let anyone with the file test guesses.
        let record = try await store.capture()[0]
        let unkeyed = try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(record))
        check(bytes.range(of: Data(unkeyed.utf8)) == nil)
        // A new epoch starts with nothing marked.
        try await client.coordinator.reset()
        let afterReset = adapter()
        await afterReset.useOutbox(queue: "fixture-queue")
        check(try await afterReset.changedSnapshot(cut: cut).operations.count == 2)
    }
    func testNativeCanonicalFormMatchesTheECMAScriptFormatter() throws {
        let tricky = NativeRPCValue.object([
            .init("b", .number(1)), .init("B", .bool(true)), .init("a", .string("q\"\\/\u{0}\u{1f}\u{7f}\n\t\r\u{8}\u{c}\u{2028}é😀")),
            .init("é", .null), .init("😀", .array([.number(-0.0), .number(-42), .number(9_007_199_254_740_991)])),
            // UTF-16 order puts the surrogate pair (D800) before U+FFFF.
            .init("\u{10000}", .string("x")), .init("\u{ffff}", .string("y")), .init("nested", .object([.init("z", .array([])), .init("y", .object([]))]))])
        let value = CloudValue(tricky)
        var nativeTricky = Data()
        check(CloudSecretsCanonical.emit(try NativeRPCValue.parseJSON(JSONEncoder().encode(value)), into: &nativeTricky))
        check(try CloudSecretsCanonical.encode(value) == CloudSecretsCanonical.isolatedRender(JSONEncoder().encode(value)))
        // Numbers are formatted natively too (no engine per cookie), exactly as
        // ECMAScript Number::toString does.
        let numbers = CloudValue(.object([.init("x", .number(1.5)), .init("y", .number(1e21)), .init("z", .number(1e-7))]))
        check(String(decoding: try CloudSecretsCanonical.encode(numbers), as: UTF8.self) == #"{"x":1.5,"y":1e+21,"z":1e-7}"#)
        let samples: [Double] = [0, -0.0, 1, -1, 0.1, 0.5, 1.5, -2.25, 1e-6, 1e-7, 1.234e-7, 123456789.123, 1767225600.5, 1767225600.123456,
                                 1e20, 1e21, 1.5e21, 9007199254740991, 9007199254740992, 18446744073709551616, 5e-324, 1.7976931348623157e308,
                                 0.000001234, 100, 1e15, 123e18, 3.14159, 2.5e-5, -9.87654321e-10]
        let array = CloudValue(.array(samples.map(NativeRPCValue.number)))
        var native = Data()
        check(CloudSecretsCanonical.emit(.array(samples.map(NativeRPCValue.number)), into: &native))
        check(native == (try CloudSecretsCanonical.isolatedRender(JSONEncoder().encode(array))))
        // The root-carrying device body takes the native path, byte-exact.
        let rootKey = CloudSecretsCrypto.encode(Data(repeating: 7, count: 32)), canary = CloudSecretsCrypto.encode(Data(repeating: 9, count: 32))
        let body = CloudSecretsUnwrapped(epoch: 3, rootKey: rootKey, recoveryVersion: CloudSequence(2), canary: canary)
        var bodyBytes = Data()
        check(CloudSecretsCanonical.emit(try NativeRPCValue.parseJSON(JSONEncoder().encode(body)), into: &bodyBytes))
        check(String(decoding: try CloudSecretsCanonical.encode(body), as: UTF8.self)
              == #"{"canary":""# + canary + #"","epoch":3,"recoveryVersion":"2","rootKey":""# + rootKey + #""}"#)
    }
    func testALostRebuiltOrUnknownQueueNeverLeavesAnUnchangedSecretSkipped() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-known-" + UUID().uuidString.lowercased())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let known = BackendCloudSecretsKnown(dataRoot: root, requireWriter: {})
        let store = CloudSecretsKnownFixtureStore(), journal = CloudSecretsFixtureJournal()
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:])
        func adapter(queue: String?) async -> CloudSecretsLogicalAdapter {
            let made = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
                keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) }, known: known)
            await made.useOutbox(queue: queue)
            return made
        }
        let first = await adapter(queue: "queue-one")
        let queued = try await first.changedSnapshot(cut: cut)
        let receipt = try await journal.enqueue(queued.operations)
        try await first.markPublished(queued, receipt: receipt)
        // Queued, not yet confirmed: an app start does not queue it again (the
        // waiting list is kept beside the marks), and nothing is marked uploaded.
        check(try await adapter(queue: "queue-one").changedSnapshot(cut: cut).operations.isEmpty)
        let restartedFirst = await adapter(queue: "queue-one")
        _ = try await restartedFirst.changedSnapshot(cut: cut)
        check(await Set(restartedFirst.pendingOperationIds()) == Set(queued.operations.map(\.opId)))
        await first.confirmed(operationIds: Set(queued.operations.map(\.opId)))
        check(try await adapter(queue: "queue-one").changedSnapshot(cut: cut).operations.isEmpty) // same queue, confirmed: skipped
        check(try await adapter(queue: "queue-two").changedSnapshot(cut: cut).operations.count == 2) // rebuilt queue: all again
        check(try await adapter(queue: nil).changedSnapshot(cut: cut).operations.count == 2) // no identity: nothing persisted is trusted
    }
    func testARecordTooLargeToSendIsReportedNeitherQueuedNorMarked() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let store = CloudSecretsKnownFixtureStore()
        await store.set("big", String(repeating: "x", count: 300_000))
        let outbox = CloudSecretsFixtureOutbox()
        let adapter = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
            outbox: outbox, adapters: [adapter], prepareSynchronization: {}, restoreLocalStores: {})
        let receipt = try await service.captureChanged(sourceId: store.sourceId)
        check(receipt.queued == 2) // "one" and "two"; "big" stays here
        check(await outbox.queued.allSatisfy { $0.entityId != "big" })
        let words = await service.gaps()[store.sourceId] ?? []
        check(words == ["An app sign-in is too large to save in Cloud. It stays on this Mac."])
        // The status tool carries the gap and never says protected or finished.
        let tools = BackendCloudSecretsTools(secrets: service, policy: client.policy, browser: { _, _ in
            .init(cookies: 0, passwords: 0, needsSignIn: 0, expired: 0, conflicts: 0) })
        let shown = try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("status"))])))
        check(shown.raw["protected"].bool == false && shown.raw["gapCount"].number == 1)
        check(shown.raw["message"].string?.contains("too large to save in Cloud") == true)
        check(shown.raw["message"].string?.contains("Finished") == false)
        // Not marked: it is measured and reported again, never treated as sent.
        let again = try await service.captureChanged(sourceId: store.sourceId)
        check(again.queued == 0)
        check((await service.gaps()[store.sourceId] ?? []).count == 1)
    }
    func testCoverageRightAfterAStartNeverCountsATooLargeRecordAsSaved() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let store = CloudSecretsKnownFixtureStore()
        await store.set("big", String(repeating: "x", count: 300_000))
        // A fresh adapter (an app start): no capture has measured anything yet.
        let adapter = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        let inventory = try await adapter.sourceInventory()
        check(inventory.first?.complete == false && inventory.first?.items == 2)
        check(inventory.first?.blockedReasons == ["An app sign-in is too large to save in Cloud. It stays on this Mac."])
    }
    func testTheSizeEstimateNeverFlagsARecordTheCloudAlreadyHas() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-known-" + UUID().uuidString.lowercased())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let known = BackendCloudSecretsKnown(dataRoot: root, requireWriter: {})
        let store = CloudSecretsKnownFixtureStore(), journal = CloudSecretsFixtureJournal()
        // Just under the payload limit, but above the conservative estimate.
        await store.set("near", String(repeating: "y", count: 48_400))
        func adapter() async -> CloudSecretsLogicalAdapter {
            let made = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
                keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) }, known: known)
            await made.useOutbox(queue: "fixture-queue")
            return made
        }
        let first = await adapter()
        let sent = try await first.changedSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:]))
        check(sent.operations.contains { $0.entityId == "near" }) // it fits when measured exactly
        let receipt = try await journal.enqueue(sent.operations)
        try await first.markPublished(sent, receipt: receipt)
        await first.confirmed(operationIds: Set(sent.operations.map(\.opId)))
        // After a start, nothing measured yet: the cloud has it, so it is not flagged.
        let inventory = try await adapter().sourceInventory()
        check(inventory.first?.complete == true && inventory.first?.blockedReasons.isEmpty == true)
    }
    func testEveryCallerOfTheAdapterHonoursTheRecordLimitsAndCoverageSaysSo() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let store = CloudSecretsKnownFixtureStore()
        await store.set("big", String(repeating: "x", count: 300_000))
        // Called directly, as the sync core's bootstrap does: no service, no outbox facts.
        let adapter = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        let page = try await adapter.snapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:]))
        check(page.operations.count == 2 && page.operations.allSatisfy { $0.entityId != "big" })
        check(page.coverage.first?.complete == false)
        check(page.coverage.first?.blockedReasons == ["An app sign-in is too large to save in Cloud. It stays on this Mac."])
        let inventory = try await adapter.sourceInventory()
        check(inventory.first?.complete == false && inventory.first?.items == 2) // not counted as saved
        check(inventory.first?.blockedReasons.count == 1)
        // The gap stays until that record changes, whatever other snapshots run.
        _ = try await adapter.snapshot(records: [], cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 2, watermarks: [:]))
        check(await adapter.gaps().count == 1)
        await store.set("big", "small now")
        _ = try await adapter.snapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 3, watermarks: [:]))
        check(await adapter.gaps().isEmpty)
    }
}
