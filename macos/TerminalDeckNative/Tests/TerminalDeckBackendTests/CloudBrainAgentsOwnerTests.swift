import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudBrainAgentsOwnerTests: XCTestCase, @unchecked Sendable {
  private let worker: NativeRPCValue = .object([.init("id", .string("worker")), .init("name", .string("Worker")), .init("provider", .string("claude"))])
  private func owners(_ root: URL) async throws -> (BackendTaskConfiguration, BackendTaskConfiguration, CloudBrainAgentsAdapter, CloudBrainAgentsAdapter) {
    let a = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("a"), ownership: .exclusive))
    let b = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("b"), ownership: .exclusive))
    try await a.start(); try await b.start()
    return (a, b, BackendCloudBrainAgents.adapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device)),
      BackendCloudBrainAgents.adapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)))
  }

  /// I10 without the old vault: the roster restores from task-config records alone and the source bytes stay as they were.
  func testRosterRestoresWithoutTheVaultAndLeavesSourceBytes() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, adapterA, adapterB) = try await owners(root)
    _ = try await a.saveAgent(worker)
    let source = root.appendingPathComponent("a/task-config.json")
    let before = try Data(contentsOf: source)
    try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    let restored = try await b.allAgents()
    XCTAssertEqual(restored.map { $0["id"].string }, ["worker"])
    XCTAssertTrue(try Data(contentsOf: source) == before)
  }

  /// Finding 9: rows are exported exactly as stored (unknown fields, a row this version no longer reads), together
  /// with connections, import choices, pending reviews and unknown top-level keys; nothing blocks the roster.
  func testStoredRowsExportByteExactIncludingUnknownFieldsAndUnreadableRows() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let newer = worker.setting("futureField", .object([.init("kept", .bool(true))]))
    let unreadable: NativeRPCValue = .object([.init("id", .string("Bad Id!")), .init("name", .string("Unreadable"))])
    let connection: NativeRPCValue = .object([.init("keyId", .string("crm")), .init("hasEventsSecret", .bool(true))])
    let plan: NativeRPCValue = .object([.init("planId", .string("plan-1")), .init("keyId", .string("crm")), .init("entries", .array([]))])
    let config: NativeRPCValue = .object([.init("v", .number(1)), .init("agents", .array([newer, unreadable])), .init("connections", .array([connection])),
      .init("agentImportSelections", .object([.init("/fixture/.claude/agents", .array([.string("/fixture/.claude/agents/a.md")]))])), .init("profileChangePlans", .array([plan])),
      .init("futureTopLevel", .string("kept"))])
    // A saved import choice is a project's .claude/agents folder and absolute .md paths inside it; anything else is
    // refused at start (readImportSelections, since 10-11 Oct), so the fixture stores a real-shaped one.
    try CloudBrainAgentsFixture.write(config.encodedJSON(), to: root.appendingPathComponent("a/task-config.json"))
    let (_, b, adapterA, adapterB) = try await owners(root)
    let snapshot = try await adapterA.snapshot(cut: CloudBrainAgentsFixture.cut)
    let byKind = Dictionary(grouping: snapshot.operations, by: { $0.payload.raw["kind"].string ?? "" })
    XCTAssertEqual(byKind["agent"]?.count, 2, "The unreadable row is exported, not dropped and not blocking")
    XCTAssertEqual(byKind["agent"]?.first { $0.payload.raw["id"].string == "worker" }?.payload.raw["record"], newer)
    XCTAssertEqual(byKind["connection"]?.first?.payload.raw["record"], connection)
    XCTAssertNotNil(byKind["import-selections"])
    XCTAssertEqual(byKind["profile-plan"]?.count, 1)
    XCTAssertEqual(byKind["extra"]?.first?.payload.raw["record"].string, "kept")
    let receipt = try await CloudBrainAgentsFixture.deliver(snapshot.operations, to: adapterB)
    XCTAssertFalse(receipt.results.contains { $0.status == .blocked })
    let restored = try await b.allAgents()
    XCTAssertEqual(restored.map { $0["id"].string }, ["worker"], "Only readable agents are shown; the rest stays in history with a reason")
    let coverage = try await adapterA.sourceInventory()
    XCTAssertTrue(coverage[0].blockedReasons.contains { $0.contains("connected-task definitions") }, "History-only parts are named in coverage")
  }

  /// Finding 1: an agent edit made on A reaches B that already shows the agent.
  func testAgentEditOnAReachesB() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, adapterA, adapterB) = try await owners(root)
    _ = try await a.saveAgent(worker)
    let first = try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    _ = try await a.saveAgent(worker.setting("name", .string("Worker Renamed")))
    let later = try await CloudBrainAgentsFixture.ownChanges(adapterA, after: first.operations.last?.opId)
    XCTAssertFalse(later.isEmpty)
    let receipt = try await CloudBrainAgentsFixture.deliver(later, to: adapterB, sequence: 2)
    XCTAssertTrue(receipt.results.allSatisfy { $0.status == .applied })
    let shown = try await b.agent("worker")
    XCTAssertEqual(shown?["name"].string, "Worker Renamed")
  }

  /// Finding 13: a new agent whose id already has a different instruction file here is not run with it.
  func testNewAgentWithADifferentLocalInstructionFileIsKeptInHistoryNotRun() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, adapterA, adapterB) = try await owners(root)
    _ = try await a.saveAgent(worker)
    let stale = Data("instructions left by a deleted agent\n".utf8)
    try CloudBrainAgentsFixture.write(stale, to: root.appendingPathComponent("b/agent-instructions/worker.md"))
    let snapshot = try await adapterA.snapshot(cut: CloudBrainAgentsFixture.cut)
    let receipt = try await CloudBrainAgentsFixture.deliver(snapshot.operations, to: adapterB)
    XCTAssertEqual(receipt.results.first { $0.entityId == "agent:worker" }?.status, .keptBoth)
    let agents = try await b.allAgents()
    XCTAssertTrue(agents.isEmpty)
    XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent("b/agent-instructions/worker.md")) == stale)
  }

  /// Exact instruction bytes far above one payload survive, and the cloud copy is shown when the file is new here.
  func testInstructionBytesBeyondOnePayloadSurviveExactly() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, _, adapterA, adapterB) = try await owners(root)
    _ = try await a.saveAgent(worker)
    let original = Data(("  \n" + String(repeating: "字", count: 24_000) + "\n  ").utf8)
    XCTAssertGreaterThan(original.count, 65_536)
    let source = root.appendingPathComponent("a/agent-instructions/worker.md")
    try? FileManager.default.removeItem(at: source)
    try CloudBrainAgentsFixture.write(original, to: source)
    try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent("b/agent-instructions/worker.md")) == original)
    XCTAssertTrue(try Data(contentsOf: source) == original)
  }

  /// S04: both Macs edit the same agent; each keeps its own edit and both versions are retained.
  func testS04ConcurrentAgentEditsKeepBoth() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, adapterA, adapterB) = try await owners(root)
    _ = try await a.saveAgent(worker)
    let first = try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    _ = try await a.saveAgent(worker.setting("role", .string("A edit")))
    _ = try await b.saveAgent(worker.setting("role", .string("B edit")))
    let fromA = try await CloudBrainAgentsFixture.ownChanges(adapterA, after: first.operations.last?.opId)
    let fromB = try await CloudBrainAgentsFixture.ownChanges(adapterB, after: nil)
    let toB = try await CloudBrainAgentsFixture.deliver(fromA, to: adapterB, sequence: 2)
    try await CloudBrainAgentsFixture.deliver(fromB, to: adapterA, sequence: 3)
    XCTAssertTrue(toB.results.contains { $0.status == .keptBoth })
    let localA = try await a.agent("worker"), localB = try await b.agent("worker")
    XCTAssertEqual(localA?["role"].string, "A edit")
    XCTAssertEqual(localB?["role"].string, "B edit")
    for owner in [a, b] {
      let heads = try CloudSyncPack.heads(try await owner.cloudAgentVersions()).filter { $0.entityId == "agent:worker" }
      XCTAssertEqual(Set(heads.compactMap { $0.payload.raw["record"]["role"].string }), ["A edit", "B edit"])
    }
  }
}

final class CloudBrainAgentsOptionsTests: XCTestCase, @unchecked Sendable {
  private func store(_ directory: URL, usable: Bool = true) -> BackendAGSStore {
    BackendAGSStore(persistence: try! .init(directory: directory, ownership: .exclusive), cipher: CloudBrainAgentsFixtureCipher(usable: usable))
  }

  /// Finding 3: a restored option the person deleted stays deleted after restart and is not re-uploaded.
  func testDeletedRestoredOptionStaysDeletedAfterRestart() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = store(root.appendingPathComponent("a")), b = store(root.appendingPathComponent("b"))
    try await a.start(); try await b.start()
    try await a.saveProfile("worker", settings: .init(provider: "claude", effort: "high"), expectedRevision: 0)
    let accountB = CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)
    try await CloudBrainAgentsFixture.roundTrip(BackendCloudBrainAgents.optionsAdapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device)),
      BackendCloudBrainAgents.optionsAdapter(owner: b, account: accountB))
    let restored = try await b.profile("worker")
    XCTAssertEqual(restored?.effort, "high")
    try await b.removeProfile("worker", expectedRevision: try await b.currentRevision())
    let removal = try await b.cloudOptionsOwnChanges(after: nil, limit: 64)
    XCTAssertEqual(removal.map(\.kind), [.archive])
    let restarted = store(root.appendingPathComponent("b"))
    try await restarted.start()
    let afterRestart = try await restarted.profile("worker")
    XCTAssertNil(afterRestart)
    let adapter = BackendCloudBrainAgents.optionsAdapter(owner: restarted, account: accountB)
    _ = try await adapter.snapshot(cut: CloudBrainAgentsFixture.cut)
    let own = try await restarted.cloudOptionsOwnChanges(after: nil, limit: 64)
    XCTAssertEqual(own, removal, "No new put re-adds the deleted option")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b/ags-cloud-portable.json").path))
  }

  /// Finding 4: with the vault locked nothing starts, so no launch can read stripped settings; Cloud options wait in history.
  func testLockedVaultRefusesLaunchSettingsAndKeepsCloudOptionsInHistory() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = store(root.appendingPathComponent("a"))
    try await a.start()
    try await a.saveProfile("worker", settings: .init(provider: "claude", effort: "high"), expectedRevision: 0)
    let oldVault = root.appendingPathComponent("b/ags-settings.json")
    let old = Data("{\"version\":1,\"encrypted\":\"Zml4dHVyZQ==\"}".utf8)
    try CloudBrainAgentsFixture.write(old, to: oldVault)
    // A side file from the previous build must not be merged into launch settings any more.
    try CloudBrainAgentsFixture.write(Data("{\"version\":1,\"defaults\":{},\"profiles\":{}}".utf8), to: root.appendingPathComponent("b/ags-cloud-portable.json"))
    let b = store(root.appendingPathComponent("b"), usable: false)
    let receipt = try await CloudBrainAgentsFixture.roundTrip(BackendCloudBrainAgents.optionsAdapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device)),
      BackendCloudBrainAgents.optionsAdapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)))
    _ = receipt
    do { try await b.start(); XCTFail("A locked vault must not start") } catch {}
    do { _ = try await b.profile("worker"); XCTFail("Launch settings must not be readable while locked") } catch {}
    let history = try await b.cloudOptionsVersions()
    XCTAssertEqual(history.count, 1)
    XCTAssertTrue(try Data(contentsOf: oldVault) == old)
  }

  /// Finding 1 for options: A's later edit reaches B; B's own environment and hooks stay on B.
  func testOptionEditReachesBAndKeepsBsOwnSecrets() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = store(root.appendingPathComponent("a")), b = store(root.appendingPathComponent("b"))
    try await a.start(); try await b.start()
    try await a.saveProfile("worker", settings: .init(provider: "claude", effort: "high"), expectedRevision: 0)
    let adapterA = BackendCloudBrainAgents.optionsAdapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device))
    let adapterB = BackendCloudBrainAgents.optionsAdapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB))
    let first = try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    let current = try await b.profile("worker")
    var local = try XCTUnwrap(current); local.environment = ["FIXTURE": "fixture-only"]
    try await b.saveProfile("worker", settings: local, expectedRevision: try await b.currentRevision())
    let afterLocal = try await CloudBrainAgentsFixture.ownChanges(adapterB, after: nil)
    XCTAssertTrue(afterLocal.isEmpty, "An environment-only change is not shared")
    try await a.saveProfile("worker", settings: .init(provider: "claude", effort: "low"), expectedRevision: try await a.currentRevision())
    try await CloudBrainAgentsFixture.deliver(try await CloudBrainAgentsFixture.ownChanges(adapterA, after: first.operations.last?.opId), to: adapterB, sequence: 2)
    let after = try await b.profile("worker")
    let shown = try XCTUnwrap(after)
    XCTAssertEqual(shown.effort, "low")
    XCTAssertEqual(shown.environment, ["FIXTURE": "fixture-only"])
  }
}
