import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudBrainProjectsSettingsOwnerTests: XCTestCase, @unchecked Sendable {
  private let accountA = CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device)
  private let accountB = CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)

  /// Finding 11 + S14: shared project records carry stable rootIds and no absolute path; two projects with the same
  /// folder name on different paths stay separate; folders appear on B only where B's path map says.
  func testProjectsShareRootIDsNotPathsAndSameNamedFoldersStaySeparate() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = BackendPROJRegistry(fileURL: root.appendingPathComponent("a/projects.registry.json"))
    let b = BackendPROJRegistry(fileURL: root.appendingPathComponent("b/projects.registry.json"))
    _ = try await a.save(PROJProject(id: "one", name: "One", folders: ["/fixture/work/app"]))
    _ = try await a.save(PROJProject(id: "two", name: "Two", folders: ["/fixture/other/app"]))
    let pathsA = CloudBrainProjectsFixturePaths(), pathsB = CloudBrainProjectsFixturePaths()
    let adapterA = BackendCloudBrainProjects.adapter(owner: a, account: accountA, paths: pathsA.port)
    let adapterB = BackendCloudBrainProjects.adapter(owner: b, account: accountB, paths: pathsB.port)
    let snapshot = try await adapterA.snapshot(cut: CloudBrainAgentsFixture.cut)
    let text = String(decoding: try CloudSyncPack.encode(snapshot.operations), as: UTF8.self)
    XCTAssertFalse(text.contains("/fixture/"), "No absolute path in a shared project record")
    let rootOne = try XCTUnwrap(snapshot.operations.first { $0.entityId == "one" }?.payload.raw["roots"].elements?.first?.string)
    let rootTwo = try XCTUnwrap(snapshot.operations.first { $0.entityId == "two" }?.payload.raw["roots"].elements?.first?.string)
    XCTAssertNotEqual(rootOne, rootTwo)
    let published = await pathsA.published
    XCTAssertEqual(Set(published.map(\.path)), ["/fixture/work/app", "/fixture/other/app"], "Paths go only to the per-device path map")
    await pathsB.map("one", rootOne, to: "/fixture/b/one/app")
    try await CloudBrainAgentsFixture.deliver(snapshot.operations, to: adapterB)
    let projects = try await b.projects()
    XCTAssertEqual(projects.first { $0.id == "one" }?.folders, ["/fixture/b/one/app"])
    XCTAssertEqual(projects.first { $0.id == "two" }?.folders, [], "An unmapped root is never guessed from the folder name")
    // The same root keeps its id on the second Mac: nothing new is shared after B saves its own registry again.
    let again = try await adapterB.snapshot(cut: CloudBrainAgentsFixture.cut)
    XCTAssertTrue(again.operations.isEmpty)
  }

  /// Finding 1 for settings: A's later change reaches B where B left the value alone; a value B changed is kept.
  func testSettingEditReachesBUnlessBChangedItToo() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = BackendAppSettingsStore(userData: root.appendingPathComponent("a"), writable: true)
    let b = BackendAppSettingsStore(userData: root.appendingPathComponent("b"), writable: true)
    _ = try await a.patch(.object([.init("theme", .string("dark")), .init("fontSize", .number(13))]))
    let adapterA = BackendCloudBrainSettings.adapter(owner: a, account: accountA)
    let adapterB = BackendCloudBrainSettings.adapter(owner: b, account: accountB)
    let first = try await CloudBrainAgentsFixture.roundTrip(adapterA, adapterB)
    _ = try await b.patch(.object([.init("fontSize", .number(18))]))
    _ = try await a.patch(.object([.init("theme", .string("light")), .init("fontSize", .number(15))]))
    let later = try await CloudBrainAgentsFixture.ownChanges(adapterA, after: first.operations.last?.opId)
    let receipt = try await CloudBrainAgentsFixture.deliver(later, to: adapterB, sequence: 2)
    XCTAssertEqual(receipt.results.first { $0.entityId == "theme" }?.status, .applied)
    XCTAssertEqual(receipt.results.first { $0.entityId == "fontSize" }?.status, .keptBoth)
    let values = await b.get()["values"]
    XCTAssertEqual(values["theme"].string, "light")
    XCTAssertEqual(values["fontSize"].number, 18)
  }
}

final class CloudBrainAgentsAccountTests: XCTestCase, @unchecked Sendable {
  private func task(_ id: String) -> NativeRPCValue {
    .object([.init("id", .string("local:" + id)), .init("keyId", .string("local")), .init("externalTaskId", .string(id)),
      .init("local", .bool(true)), .init("title", .string("Fixture")), .init("process", .string("queued")), .init("sessionId", .null)])
  }

  /// Finding 8: after signing out of account X and into Y, nothing X brought to this Mac is uploaded into Y,
  /// and X's imported revisions were never offered for upload in the first place.
  func testSwitchingAccountsUploadsNothingFromThePreviousAccount() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("a"), ownership: .exclusive))
    let b = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("b"), ownership: .exclusive))
    try await a.start(); try await b.start()
    _ = try await a.put(task("from-x"), now: true)
    let adapterA = BackendCloudBrainTasks.adapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device), projects: nil)
    let inX = BackendCloudBrainTasks.adapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB), projects: nil)
    try await CloudBrainAgentsFixture.roundTrip(adapterA, inX)
    let offeredInX = try await CloudBrainAgentsFixture.ownChanges(inX, after: nil)
    XCTAssertTrue(offeredInX.isEmpty, "Imported revisions are never re-sent")
    let outboxX = CloudBrainAgentsFixtureOutbox()
    let pumpX = CloudBrainAgentsPump(adapter: inX, outbox: outboxX)
    await pumpX.stop() // sign-out detaches the owner
    let inY = BackendCloudBrainTasks.adapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB, subject: CloudBrainAgentsFixture.subjectY), projects: nil)
    let snapshotY = try await inY.snapshot(cut: CloudBrainAgentsFixture.cut)
    XCTAssertTrue(snapshotY.operations.isEmpty)
    XCTAssertTrue(snapshotY.coverage.first?.blockedReasons.contains { $0.contains("another Cloud account") } == true)
    _ = try await b.put(task("made-in-y"), now: true)
    let offeredInY = try await CloudBrainAgentsFixture.ownChanges(inY, after: nil)
    XCTAssertEqual(offeredInY.compactMap { $0.payload.raw["id"].string }, ["local:made-in-y"], "This Mac's own new work still goes to Y")
  }

  /// The pump hands only own revisions to the outbox and advances its cursor only after a local receipt.
  func testPumpAdvancesOnlyAfterTheOutboxKeptTheRevisions() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = BackendTaskStore(persistence: try .init(directory: root.appendingPathComponent("a"), ownership: .exclusive))
    try await a.start()
    let adapter = BackendCloudBrainTasks.adapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device), projects: nil)
    _ = try await adapter.snapshot(cut: CloudBrainAgentsFixture.cut)
    _ = try await a.put(task("one"), now: true)
    let outbox = CloudBrainAgentsFixtureOutbox(), pump = CloudBrainAgentsPump(adapter: adapter, outbox: outbox)
    await outbox.failOnce()
    do { _ = try await pump.drainOnce(); XCTFail("The outbox refused once") } catch {}
    let cursorAfterFailure = try await a.cloudTaskCursor()
    XCTAssertNil(cursorAfterFailure)
    let drained = try await pump.drainOnce()
    let nothingLeft = try await pump.drainOnce()
    XCTAssertEqual(drained, 1)
    XCTAssertEqual(nothingLeft, 0)
    let sent = await outbox.enqueued
    XCTAssertEqual(sent.compactMap { $0.payload.raw["id"].string }, ["local:one"])
  }
}
