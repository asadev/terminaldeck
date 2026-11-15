import Foundation
import Darwin
import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor CloudBackupWatchFixture: BackendCloudBackupWatching {
  var watched = 0
  var removed = 0
  var captures = 0
  var states: [BackendCloudBackupWatcher.State] = []
  func watch(folder: String, context: NativeRPCContext) { watched += 1 }
  func unwatch(folder: String, ownerId: String) { removed += 1 }
  func capture() { captures += 1 }
  func state(_ state: BackendCloudBackupWatcher.State) { states.append(state) }
}
final class CloudBackupWatcherTests: XCTestCase, @unchecked Sendable {
  func testIgnoredFileEventsCoalesceThroughSharedRegistryAndStopCleanly() async throws {
    let notes = try CloudBackupDirectory(path: "/Users/imatch/Deck Dev/notes")
    if mkdirat(notes.fd, "cloud-test-20261112", 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
    let day = try notes.directory("cloud-test-20261112")
    if mkdirat(day.fd, "bkp", 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
    let scope = try day.directory("bkp"), id = UUID().uuidString
    let owned = try scope.createDirectory(id)
    _ = try owned.createDirectory("source")
    let base = URL(fileURLWithPath: "/Users/imatch/Deck Dev/notes/cloud-test-20261112/bkp").appendingPathComponent(id)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source")
    try Data("ignored.data\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
    try Data("fixture".utf8).write(to: source.appendingPathComponent("ignored.data"))
    let fixture = CloudBackupWatchFixture(), ports = CloudToolsSitePorts(), registry = NativeChannelRegistry()
    let engine = CloudBackupEngine(stateDirectory: base.appendingPathComponent("state"), brain: ports, secrets: ports,
      classify: { _, _ in .init(storageClass: .brain, purpose: .brain, rule: "fixture") }, outbox: ports)
    let context = NativeRPCContext(caller: .nativeApp, ownerID: "cloud-backup:fixture")
    let watcher = try BackendCloudBackupWatcher(registry: registry, events: fixture, context: context, allowed: { true }, capture: { root, cursor in
      await fixture.capture()
      return try await engine.snapshot(root, eventCursor: cursor, at: 1)
    }, report: { _, state in await fixture.state(state) }, debounce: .milliseconds(100))
    do {
      try await watcher.replaceProjectRoots([.init(projectId: "fixture", rootId: "root", deviceId: "fixture", directory: source)])
      for _ in 0..<3 { try await registry.publish("fs:changed", arguments: [.string(source.path)], ownerID: context.ownerID) }
      let deadline = Date().addingTimeInterval(3)
      while Date() < deadline {
        if await fixture.states.contains(.savedLocally), await watcher.pendingCount() == 0 { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let count = await fixture.captures, states = await fixture.states
      XCTAssertEqual(count, 1)
      XCTAssertTrue(states.contains(.savedLocally))
      await watcher.stop()
      try await registry.publish("fs:changed", arguments: [.string(source.path)], ownerID: context.ownerID)
      try await Task.sleep(for: .milliseconds(80))
      let finalCount = await fixture.captures, removed = await fixture.removed
      XCTAssertEqual(finalCount, 1)
      XCTAssertEqual(removed, 1)
    } catch { await watcher.stop(); throw error }
  }
}
