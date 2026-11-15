import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture paths shared by the project and task tests: lane A's path map stand-in.
actor CloudBrainProjectsFixturePaths {
  private(set) var published: [CloudBrainProjectRoot] = []
  private var mapped: [String: String] = [:]
  func map(_ project: String, _ root: String, to path: String) { mapped[project + "\n" + root] = path }
  func lookup(_ project: String, _ root: String) -> String? { mapped[project + "\n" + root] }
  func publish(_ root: CloudBrainProjectRoot) { published.append(root) }
  nonisolated var port: BackendCloudBrainProjectPaths {
    .init(map: { try await self.lookup($0, $1) }, publish: { await self.publish($0) })
  }
}

final class CloudBrainTasksOwnerTests: XCTestCase, @unchecked Sendable {
  private func task(_ id: String) -> NativeRPCValue {
    .object([.init("id", .string("local:" + id)), .init("keyId", .string("local")), .init("externalTaskId", .string(id)),
      .init("local", .bool(true)), .init("title", .string("Fixture")), .init("process", .string("queued")),
      .init("sessionId", .null), .init("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("worker"))]))])
  }
  private func pair(_ root: URL, changed: (@Sendable () async -> Void)? = nil) async throws -> (BackendTaskStore, BackendTaskStore, CloudBrainAgentsAdapter, CloudBrainAgentsAdapter) {
    let a = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("a"), ownership: .exclusive))
    let b = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("b"), ownership: .exclusive), changed: changed ?? {})
    try await a.start(); try await b.start()
    return (a, b, BackendCloudBrainTasks.adapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device), projects: nil),
      BackendCloudBrainTasks.adapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB), projects: nil))
  }

  /// Finding 1: A edits a task B already holds and moves it to Trash; B shows both, and each result is `applied`.
  func testEditAndTrashMoveOnAReachBThatAlreadyHasTheTask() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, adapterA, adapterB) = try await pair(root)
    _ = try await a.put(task("one"), now: true)
    let first = try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    _ = try await a.put(task("one").setting("title", .string("Renamed on A")), now: true)
    try await a.moveToTrash("local:one")
    let later = try await CloudBrainAgentsFixture.ownChanges(adapterA, after: first.operations.last?.opId)
    XCTAssertEqual(later.count, 2)
    let receipt = try await CloudBrainAgentsFixture.deliver(later, to: adapterB, sequence: 2)
    XCTAssertEqual(receipt.results.map(\.status), [.applied, .applied])
    let shown = try await b.byID("local:one", includeTrash: true)
    XCTAssertEqual(shown?.value["title"].string, "Renamed on A")
    let trash = try await b.inTrash(), live = try await b.all()
    XCTAssertEqual(trash.map(\.id), ["local:one"])
    XCTAssertTrue(live.isEmpty)
    let echo = try await CloudBrainAgentsFixture.ownChanges(adapterB, after: nil)
    XCTAssertTrue(echo.isEmpty, "Showing A's edits is not a new edit on B")
  }

  /// Finding 2: one task far above 64 KiB travels in parts, arrives whole, and later task saves are still captured.
  func testTaskOver64KiBDoesNotStopTaskSync() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let details = String(repeating: "یہ ایک لمبا کام ہے۔ ", count: 1_000)
    let notes: NativeRPCValue = .array((0..<40).map { .object([.init("text", .string("\($0) " + details))]) })
    let big = task("big").setting("details", .string(details)).setting("notes", notes)
    let persistence = try BackendTaskPersistence(directory: root.appendingPathComponent("a"), ownership: .exclusive)
    try persistence.write("tasks.json", value: .object([.init("v", .number(1)), .init("tasks", .array([big])), .init("trash", .array([]))]))
    let a = BackendTaskStore(persistence: persistence)
    let b = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("b"), ownership: .exclusive))
    try await a.start(); try await b.start()
    let adapterA = BackendCloudBrainTasks.adapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device), projects: nil)
    let adapterB = BackendCloudBrainTasks.adapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB), projects: nil)
    let snapshot = try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    XCTAssertGreaterThan(snapshot.operations.count, 2, "The large task travels as parts")
    let restored = try await b.byID("local:big")
    XCTAssertEqual(restored?.value["details"].string, details)
    XCTAssertEqual(restored?.value["notes"], notes)
    _ = try await a.put(task("small"), now: true)
    let later = try await CloudBrainAgentsFixture.ownChanges(adapterA, after: snapshot.operations.last?.opId)
    XCTAssertEqual(later.count, 1)
  }

  /// Finding 10: B edits the inert restored copy; the shared revision keeps A's assignee, project and run state.
  func testEditOfRestoredTaskKeepsTheOriginsAssigneeAndProject() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, adapterA, adapterB) = try await pair(root)
    _ = try await a.put(task("one").setting("project", .string("/fixture/origin/app")), now: true)
    try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    let found = try await b.byID("local:one")
    let restored = try XCTUnwrap(found)
    XCTAssertEqual(restored.assigneeKind, "none")
    XCTAssertEqual(restored.value["stopped"].bool, true)
    _ = try await b.put(restored.value.setting("title", .string("Renamed on B")), now: true)
    let bChanges = try await CloudBrainAgentsFixture.ownChanges(adapterB, after: nil)
    let edit = try XCTUnwrap(bChanges.last).payload.raw["record"]
    XCTAssertEqual(edit["title"].string, "Renamed on B")
    XCTAssertEqual(edit["assignee"]["agentId"].string, "worker")
    XCTAssertEqual(edit["project"].string, "/fixture/origin/app")
    XCTAssertEqual(edit["process"].string, "queued")
    XCTAssertTrue(edit["cloudRestoredOperation"].isNullish)
  }

  /// Finding 14: reading the inventory writes nothing and creates no revision.
  func testReadingTheInventoryCreatesNoRevision() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, _, adapterA, _) = try await pair(root)
    _ = try await a.put(task("one"), now: true)
    let first = try await adapterA.sourceInventory()
    let second = try await adapterA.sourceInventory()
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.first?.items, 1)
    let versions = try await a.cloudTaskVersions()
    XCTAssertTrue(versions.isEmpty)
    XCTAssertTrue(CloudBrainAgentsFixture.ledgerFiles(root).isEmpty)
  }

  /// Finding 14: an edit whose primary save failed is never published.
  func testFailedPrimarySaveIsNotPublished() async throws {
    if geteuid() == 0 { throw XCTSkip("Permission failure requires an ordinary user") }
    let root = try CloudBrainAgentsFixture.directory()
    let directory = root.appendingPathComponent("a")
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path); try? FileManager.default.removeItem(at: root) }
    let (a, _, adapterA, _) = try await pair(root)
    _ = try await a.put(task("one"), now: true)
    let saved = try await adapterA.snapshot(cut: CloudBrainAgentsFixture.cut)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    do { _ = try await a.put(task("one").setting("title", .string("must not publish")), now: true); XCTFail("Primary write should fail") } catch {}
    let own = try await CloudBrainAgentsFixture.ownChanges(adapterA, after: nil)
    XCTAssertEqual(own, saved.operations)
  }

  /// S17: a restored task, its finished run and its receipts have no effect; a run still working elsewhere stays history.
  func testRestoredTaskIsInertAndHasNoEffects() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try BackendTaskPersistence(directory: root.appendingPathComponent("a"), ownership: .exclusive)
    try persistence.write("tasks.json", value: .object([.init("v", .number(1)), .init("tasks", .array([task("one")])), .init("trash", .array([]))]))
    let working: NativeRPCValue = .object([.init("id", .string("run-1")), .init("agent_id", .string("worker")), .init("session_id", .string("old")), .init("started_at", .number(2_000_000_000_000))])
    let ended = working.setting("id", .string("run-2")).setting("ended_at", .number(2_000_000_100_000))
    try persistence.write("task-runs.json", value: .object([.init("v", .number(1)), .init("agentRuns", .array([working, ended])),
      .init("agentRunRollups", .object([])), .init("agentRuntimeState", .object([.init("worker", .object([.init("running", .bool(true))]))])), .init("agentHistorySince", .null)]))
    let a = BackendTaskStore(persistence: persistence)
    let effects = CloudBrainAgentsFixtureEffects()
    let b = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("b"), ownership: .exclusive), changed: { await effects.called() })
    try await a.start(); try await b.start()
    let source = try Data(contentsOf: root.appendingPathComponent("a/tasks.json"))
    let adapterB = BackendCloudBrainTasks.adapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB), projects: nil)
    let adapterA = BackendCloudBrainTasks.adapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device), projects: nil)
    try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    let restored = try await b.all()
    XCTAssertEqual(restored.count, 1)
    XCTAssertTrue(restored.allSatisfy { $0.value["stopped"].bool == true && $0.sessionID == nil && $0.process == "stopped" && $0.assigneeKind == "none" })
    let calls = await effects.calls
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent("a/tasks.json")) == source)
    let history = try await b.agentRuns("worker", now: 2_000_000_200_000)
    XCTAssertEqual(history.compactMap { $0["id"].string }, ["run-2"], "Only the finished run is shown, as history")
    let inventory = try await adapterB.sourceInventory()
    XCTAssertFalse(inventory[0].blockedReasons.contains { $0.contains("are kept in history but not shown") },
      "History kept by design (the working run, live runtime state) is not a needs-attention item")
  }

  /// S05: a different local task with the same id is untouched; retries apply once.
  func testS05ExistingTaskIsUnchangedByImportAndRetries() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, adapterA, adapterB) = try await pair(root)
    _ = try await a.put(task("one").setting("title", .string("Source")), now: true)
    _ = try await b.put(task("one").setting("title", .string("Local")), now: true)
    let before = try await b.byID("local:one")
    let snapshot = try await adapterA.snapshot(cut: CloudBrainAgentsFixture.cut)
    let first = try await CloudBrainAgentsFixture.deliver(snapshot.operations, to: adapterB)
    XCTAssertEqual(first.results.map(\.status), [.keptBoth])
    let again = try await CloudBrainAgentsFixture.deliver(snapshot.operations, to: adapterB, sequence: 2)
    XCTAssertEqual(again.results.map(\.status), [.alreadyPresent])
    let after = try await b.byID("local:one")
    XCTAssertEqual(after, before)
  }

  /// S15: a local purge adds archive markers; the original revisions stay.
  func testS15LocalPurgeAddsMarkerAndRetainsOriginalTask() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, _, adapterA, _) = try await pair(root)
    _ = try await a.put(task("one"), now: true)
    let first = try await adapterA.snapshot(cut: CloudBrainAgentsFixture.cut)
    try await a.moveToTrash("local:one")
    try await a.purgeTrash("local:one")
    let retained = try await a.cloudTaskVersions()
    XCTAssertTrue(first.operations.allSatisfy { retained.contains($0) })
    XCTAssertTrue(retained.contains { $0.kind == .archive && $0.entityId == "task:local:one" })
    let local = try await a.all(includeTrash: true)
    XCTAssertTrue(local.isEmpty)
  }

  /// Finding 11: a task names its folder by projectId/rootId; B maps it to B's own folder for that root.
  func testTaskFolderTravelsAsProjectRootAndMapsOnTheOtherMac() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let registryA = BackendPROJRegistry(fileURL: root.appendingPathComponent("a/projects.registry.json"))
    let registryB = BackendPROJRegistry(fileURL: root.appendingPathComponent("b/projects.registry.json"))
    _ = try await registryA.save(PROJProject(id: "app", name: "App", folders: ["/fixture/origin/app"]))
    let pathsA = CloudBrainProjectsFixturePaths(), pathsB = CloudBrainProjectsFixturePaths()
    let accountA = CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device), accountB = CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)
    let projectsA = BackendCloudBrainProjects.adapter(owner: registryA, account: accountA, paths: pathsA.port)
    let projectsB = BackendCloudBrainProjects.adapter(owner: registryB, account: accountB, paths: pathsB.port)
    let projectOps = try await projectsA.snapshot(cut: CloudBrainAgentsFixture.cut).operations
    let rootID = try XCTUnwrap(projectOps.first?.payload.raw["roots"].elements?.first?.string)
    await pathsB.map("app", rootID, to: "/fixture/b/app")
    try await CloudBrainAgentsFixture.deliver(projectOps, to: projectsB)
    let a = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("a"), ownership: .exclusive))
    let b = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("b"), ownership: .exclusive))
    try await a.start(); try await b.start()
    _ = try await a.put(task("one").setting("project", .string("/fixture/origin/app")), now: true)
    let tasksA = BackendCloudBrainTasks.adapter(owner: a, account: accountA, projects: registryA)
    let tasksB = BackendCloudBrainTasks.adapter(owner: b, account: accountB, projects: registryB)
    let taskOps = try await tasksA.snapshot(cut: CloudBrainAgentsFixture.cut).operations
    XCTAssertEqual(taskOps.last?.payload.raw["record"]["cloudProjectRef"]["rootId"].string, rootID)
    try await CloudBrainAgentsFixture.deliver(taskOps, to: tasksB)
    let restored = try await b.byID("local:one")
    XCTAssertEqual(restored?.project, "/fixture/b/app")
    XCTAssertTrue(restored?.value["cloudNeedsPathMapping"].isNullish == true)
  }
}
