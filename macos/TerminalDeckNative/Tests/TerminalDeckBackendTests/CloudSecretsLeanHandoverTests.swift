import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// What lane V hands lane A for the lean first version's page, status tool and sign-out guard: reasons and counts
/// for skipped items (review round 8, S-5), the sign-out guard's real facts, and every source named as saved or
/// not saved. Fixture service and fixture key store only.
private actor CloudLeanHandoverValues: CloudSecretsLogicalStore {
    nonisolated let sourceId = "handover-values"
    nonisolated let inventoryRow = "I13"
    nonisolated let domain = CloudSecretsDomain.app
    var merges = 0
    func capture() throws -> [CloudSecretRecord] {
        [try BackendCloudSecretsRecords.record(sourceId, "one", domain, ["value": "fixture-handover-value"])]
    }
    func validate(_ record: CloudSecretRecord) {}
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus { merges += 1; return .applied }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool { true }
}
@MainActor
final class CloudSecretsLeanHandoverTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudSecretsLeanHandoverTests assertions=\(assertions)") }
    func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(value, "Lean hand-over assertion", file: file, line: line)
    }
    private func status(_ tools: BackendCloudSecretsTools) async throws -> NativeRPCValue {
        try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("status"))]))).raw
    }

    /// Round-8 S-5: an item closed without being applied is counted with its plain reason and reaches the service
    /// and the status tool like the gaps; once the person has seen it, it is gone.
    func testRelabelledPutsCannotBecomeRemovalsOrSecretStatusAnswers() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let store = CloudLeanHandoverValues(), outbox = CloudSecretsFixtureOutbox()
        let adapter = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
            outbox: outbox, adapters: [adapter], prepareSynchronization: {}, restoreLocalStores: {})
        let tools = BackendCloudSecretsTools(secrets: service, policy: client.policy, browser: { _, _ in throw CloudFailure.unavailable })
        let none = await service.notices()
        check(none.isEmpty)
        let quiet = try await status(tools)
        check(quiet["skippedCount"].number == 0)
        check(quiet["skipped"].elements?.isEmpty == true)
        // A put relabelled as an archive (no typed removal, no owner with a sealed Bin): closed with a final
        // "not applied" row (R8-3: the feed never stalls), counted for the status tool, never merged or listed.
        let rows = try await store.capture()
        let put = try await adapter.snapshot(records: rows, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 0, watermarks: [:])).operations[0]
        for _ in 0..<2 {
            let removalId = UUID().uuidString.lowercased()
            let removal = CloudOperation(v: 1, opId: removalId, originDevice: put.originDevice, domain: put.domain,
                entityId: put.entityId, revision: removalId, parents: [], kind: .archive, source: put.source,
                createdAt: put.createdAt, payload: put.payload, payloadHash: put.payloadHash)
            let preparation = try await adapter.validateIncoming([removal], files: [])
            _ = try await adapter.applyPrepared(preparation, origin: .init(deviceId: put.originDevice, sequence: CloudSequence(1)))
        }
        let merges = await store.merges
        check(merges == 0)
        let noticed = await service.notices()
        check(noticed == [CloudSecretsLogicalAdapter.notAppliedWords: 2])
        let told = try await status(tools)
        check(told["skippedCount"].number == 2)
        check(told["skipped"].elements?.first?["reason"].string == CloudSecretsLogicalAdapter.notAppliedWords)
        // Nothing secret rides along with the reason.
        let encoded = try CloudSecretsCanonical.encode(CloudValue(told))
        check(encoded.range(of: Data("fixture-handover-value".utf8)) == nil)
        await service.dismissNotices()
        let after = await service.notices()
        check(after.isEmpty)
        check(try await status(tools)["skippedCount"].number == 0)
    }

    /// The sign-out guard (R5) must know that a key exists on this Mac also when it is blocked or still waiting,
    /// and whether Cloud holds the recovery copy, whatever this Mac's own key looks like right now.
    func testTheSignOutGuardSeesAKeyThatIsBlockedOrWaitingAndTheWordsOnFile() async throws {
        let server = CloudSecretsFixtureServer()
        let first = try await CloudSecretsFixtureClient(server: server), second = try await CloudSecretsFixtureClient(server: server)
        // Nothing set up anywhere: no key here, no words on file.
        let empty = await first.coordinator.signOutState()
        check(empty == .init(keyOnThisMac: false, recoveryWordsOnFile: false))
        try await first.coordinator.setup()
        let ready = await first.coordinator.signOutState()
        check(ready == .init(keyOnThisMac: true, recoveryWordsOnFile: true))
        // A Mac that never unlocked holds no key, though the account's words exist.
        let other = await second.coordinator.signOutState()
        check(other == .init(keyOnThisMac: false, recoveryWordsOnFile: true))
        // A key that exists but cannot be read right now is still a key that sign-out would strand.
        await first.local.rejectReads()
        let blocked = await first.coordinator.signOutState()
        check(blocked == .init(keyOnThisMac: true, recoveryWordsOnFile: true))
        let protection = await first.coordinator.protection()
        check(protection == .locked) // why the guard must not be built on protection() alone
        // Cloud cannot be asked: the key is still known to be here, the words are unknown (never "yes").
        await server.fault("status")
        let offline = await first.coordinator.signOutState()
        check(offline == .init(keyOnThisMac: true, recoveryWordsOnFile: nil))
        await server.fault(nil)
        // A key saved after "Codes match" that Cloud has not confirmed yet is a key on this Mac.
        let pending = try await second.coordinator.requestApproval()
        await first.local.allowReads()
        try await first.coordinator.approve(id: pending.approvalId)
        await server.fault("possession")
        do { _ = try await second.coordinator.receiveApproval(); check(false) } catch { check(true) }
        await server.fault(nil)
        let waitingProtection = await second.coordinator.protection()
        check(waitingProtection == .waitingForCloud)
        let waiting = await second.coordinator.signOutState()
        check(waiting == .init(keyOnThisMac: true, recoveryWordsOnFile: true))
    }

    /// Every source of the lean list is named: saved, or not saved with its plain reason. Never silently missing.
    func testEverySourceIsNamedAsSavedOrNotSavedAndTheStatusToolSaysSo() async throws {
        // The same list lane A admits (BackendCloudSecretsLean.sources): nothing on it can go unnamed.
        let lean = Array(BackendCloudSecretsLean.sources.keys)
        check(Set(BackendCloudSecretsLeanCoverage.order) == Set(lean))
        check(BackendCloudSecretsLeanCoverage.order.count == lean.count)
        check(BackendCloudSecretsLeanCoverage.order.first == "servers") // what Asad named first
        let none = BackendCloudSecretsLeanCoverage.lines(registered: [])
        check(none.count == lean.count)
        check(none.allSatisfy { $0.notSaved?.isEmpty == false && !$0.title.isEmpty })
        // 14 Nov (owner): project secret files joined the lean list; they can be saved, like the other three.
        let files = BackendProjectSecretFilesRules.sourceId
        check(none.contains { $0.sourceId == files && $0.title == "Project secret files"
            && $0.notSaved == "Project secret files are not being saved in Cloud from this Mac. They stay in their project folders on this Mac." })
        let bound = BackendCloudSecretsLeanCoverage.lines(registered: ["servers", "voice", "mcp-user", files])
        check(Set(bound.filter { $0.notSaved == nil }.map(\.sourceId)) == ["servers", "voice", "mcp-user", files])
        let left = BackendCloudSecretsLeanCoverage.notSaved(registered: ["servers", "voice", "mcp-user", files])
        check(left.count == 5)   // 15 Nov: WhatsApp keys joined the lean list
        // Keys travel (15 Nov): API keys, task tokens and Receiver secrets travel; only the SSH folder's line is left.
        check(left.allSatisfy { !$0.contains("not saved") && !$0.contains("in this version") && $0.contains("saved in Cloud as soon as") })
        check(left.contains { $0.hasPrefix("API keys") } && left.contains { $0.hasPrefix("Connected-task tokens") }
              && left.contains { $0.hasPrefix("Receiver secrets") } && left.contains { $0.contains("SSH settings") })
        // The status tool carries the same sentences.
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let outbox = CloudSecretsFixtureOutbox()
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
            outbox: outbox, adapters: [], prepareSynchronization: {}, restoreLocalStores: {})
        let tools = BackendCloudSecretsTools(secrets: service, policy: client.policy, browser: { _, _ in throw CloudFailure.unavailable }, notSaved: left)
        let told = try await status(tools)
        check(told["notSaved"].elements?.compactMap(\.string) == left)
        let plain = BackendCloudSecretsTools(secrets: service, policy: client.policy, browser: { _, _ in throw CloudFailure.unavailable })
        check(try await status(plain)["notSaved"].elements?.isEmpty == true)
    }
}
