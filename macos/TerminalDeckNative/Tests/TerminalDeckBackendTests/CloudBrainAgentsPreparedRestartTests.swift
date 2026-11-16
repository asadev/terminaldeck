import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudBrainAgentsPreparedRestartTests: XCTestCase, @unchecked Sendable {
  /// SYNC replays a durable preparation after an app restart; a new adapter and owner apply it from the ledger alone.
  func testLogicalPreparationReplaysWithoutAnyOldAdapterMemory() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("a"), ownership: .exclusive))
    try await source.start()
    _ = try await source.saveAgent(.object([.init("id", .string("worker")), .init("name", .string("Worker")), .init("provider", .string("claude"))]))
    let snapshot = try await BackendCloudBrainAgents.adapter(owner: source, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device)).snapshot(cut: CloudBrainAgentsFixture.cut)
    let accountB = CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)
    let owner1 = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("b"), ownership: .exclusive))
    let plan = try await BackendCloudBrainAgents.adapter(owner: owner1, account: accountB).validateIncoming(snapshot.operations, files: [])
    let serialized = try JSONEncoder().encode(plan)
    let owner2 = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("b"), ownership: .exclusive))
    try await owner2.start()
    let adapter2 = BackendCloudBrainAgents.adapter(owner: owner2, account: accountB)
    let recovered = try JSONDecoder().decode(CloudPreparedImport.self, from: serialized)
    let receipt = try await adapter2.applyPrepared(recovered, origin: .init(deviceId: CloudBrainAgentsFixture.device, sequence: CloudSequence(1)))
    let proof = try await adapter2.verify(receipt)
    XCTAssertTrue(proof.verified)
    let rows = try await owner2.allAgents()
    XCTAssertEqual(rows.count, 1)
    let duplicate = try await adapter2.applyPrepared(recovered, origin: .init(deviceId: CloudBrainAgentsFixture.device, sequence: CloudSequence(1)))
    XCTAssertTrue(duplicate.results.allSatisfy { $0.status == .alreadyPresent })
  }
}
