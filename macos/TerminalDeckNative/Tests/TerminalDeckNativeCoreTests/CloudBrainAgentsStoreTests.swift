import Foundation
import XCTest
@testable import TerminalDeckNativeCore

/// Slice 1b: every slice-1a merge test again, with each Mac's state in its own store (the store's view, image and
/// revisions are the ones checked, and each step must equal the in-memory result). Files only under
/// ~/Deck Dev/notes/cloud-test-20261112/a2.
final class CloudBrainAgentsMergeThroughStoreTests: CloudBrainAgentsMergeTests {
  private var root: URL?
  override func setUpWithError() throws {
    try super.setUpWithError()
    let folder = Self.fixtureFolder("merge")
    root = folder; CloudBrainAgentsMergeTests.storeRoot = folder
  }
  override func tearDownWithError() throws {
    CloudBrainAgentsMergeTests.storeRoot = nil
    if let root { try? FileManager.default.removeItem(at: root) }
    try super.tearDownWithError()
  }

  /// The one 1a test whose result differs by design: through the store, a version dated more than a day ahead of this
  /// Mac's service clock is refused before anything is written (review round 2, B), so it never becomes a parent.
  override func testParentAtTheLargestTimeDoesNotOverflow() throws {
    let far = CloudBrainMergeRevision(node: .init(opId: "far", parents: [], device: "x", time: .max, baseline: false), version: .init(table: 1, minTable: 1, baseline: false,
      fields: ["title": .string("T"), CloudBrainMerge.existsField: .bool(true)],
      stamps: ["title": .init(time: .max, op: "far"), CloudBrainMerge.existsField: .init(time: .max, op: "far")]))
    var mac = Mac("m")
    let store = try XCTUnwrap(mac.store)
    XCTAssertThrowsError(try mac.receive([far])) { XCTAssertEqual($0 as? CloudBrainStoreError, .tooFarAhead("far")) }
    XCTAssertEqual(try store.countsForTesting(Mac.key).nodes, 0, "Nothing of a refused version is kept")
    XCTAssertNil(try mac.view())
  }
}

/// Slice 1b: the store itself.
final class CloudBrainAgentsStoreTests: XCTestCase, @unchecked Sendable {
  private let table = CloudBrainAgentsMergeTests.table
  private let exists = CloudBrainMerge.existsField
  private var root: URL!
  private let account = try! CloudBrainAgentsAccount(subjectHash: String(repeating: "cd", count: 32), deviceID: "4f1c2b8e-0d3a-4c5b-9e7f-1a2b3c4d5e6f")

  final class Now: @unchecked Sendable { var value: Int64 = 10_000 }
  final class Fault: @unchecked Sendable {
    var point: String?
    func check(_ name: String) throws { if name == point { point = nil; throw CloudBrainStoreError.unavailable("crash at \(name)") } }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = CloudBrainAgentsMergeTests.fixtureFolder("store")
  }
  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try super.tearDownWithError()
  }

  private func folder(_ name: String) -> URL { root.appendingPathComponent("cloud/\(account.subjectHash)/\(name)") }
  private func open(_ name: String, now: Now = Now(), fault: Fault? = nil) throws -> CloudBrainAgentsStore {
    var hook: (@Sendable (String) throws -> Void)? = nil
    if let fault { hook = { name in try fault.check(name) } }
    return try CloudBrainAgentsStore(directory: folder(name), account: account, clock: .init { now.value }, fault: hook)
  }
  private func key(_ entity: String = "t1") throws -> CloudBrainRecordKey { try CloudBrainRecordKey(domain: "fixture", entity: entity) }
  private func record(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
  private var base: NativeRPCValue {
    record([("id", .string("t1")), ("title", .string("T")), ("due", .string("d0")), ("priority", .string("p0")), ("status", .string("open")),
      ("place", .string("tasks")), ("notes", .array([])), ("permissionMode", .string("default"))])
  }
  /// The owner shows the view: intent, owner write, finish.
  @discardableResult
  private func show(_ store: CloudBrainAgentsStore, _ key: CloudBrainRecordKey) throws -> NativeRPCValue? {
    let view = try store.view(key, table: table)
    let shown = view.flatMap { $0.exists ? $0.shown() : nil }
    try store.beginShow(key, heads: view?.heads ?? [], willStore: shown)
    try store.finishShow(key)
    return shown
  }

  // MARK: crash between writes

  /// A crash at any write inside a capture or a delivery rolls the whole change back: after a restart the same capture
  /// makes exactly one version, and the delivery is taken again whole.
  func testCrashInsideACaptureOrADeliveryLeavesNoExtraVersionAndLosesNone() throws {
    for point in ["capture.intent", "insert.node", "insert.payload", "capture.record"] {
      let fault = Fault(), name = "capture-\(point)", k = try key()
      var store = try open(name, fault: fault)
      _ = try XCTUnwrap(try store.capture(k, local: base, table: table, opId: "r0", device: "a"))
      let before = try store.view(k, table: table)
      let edited = base.setting("title", .string("edited"))
      fault.point = point
      XCTAssertThrowsError(try store.capture(k, local: edited, table: table, opId: "e1", device: "a"), point)
      XCTAssertEqual(try store.countsForTesting(k).nodes, 1, "\(point): no extra version")
      XCTAssertEqual(try store.view(k, table: table), before, point)
      XCTAssertEqual(try store.image(k).value, base, "\(point): the image is the one stored before")
      store = try open(name)
      XCTAssertEqual(store.opening, .existing)
      let again = try XCTUnwrap(try store.capture(k, local: edited, table: table, opId: "e1b", device: "a"), "\(point): the edit is not lost")
      XCTAssertEqual(again.parents, ["r0"])
      XCTAssertEqual(try store.countsForTesting(k).nodes, 2, "\(point): exactly one new version")
      XCTAssertEqual(try store.view(k, table: table)?.fields["title"]?.string, "edited")
    }
    for point in ["insert.node", "insert.payload", "receive.others"] {
      let fault = Fault(), name = "receive-\(point)", k = try key()
      let author = try open("author-\(point)")
      let r0 = try XCTUnwrap(try author.capture(k, local: base, table: table, opId: "r0", device: "a"))
      let r1 = try XCTUnwrap(try author.capture(k, local: base.setting("due", .string("d1")), table: table, opId: "r1", device: "a"))
      var store = try open(name, fault: fault)
      fault.point = point
      XCTAssertThrowsError(try store.receive(k, [r0, r1], table: table), point)
      XCTAssertEqual(try store.countsForTesting(k).nodes, 0, "\(point): a delivery is kept whole or not at all")
      store = try open(name)
      try store.receive(k, [r0, r1], table: table)
      XCTAssertEqual(try store.countsForTesting(k).nodes, 2)
      XCTAssertEqual(try store.view(k, table: table)?.fields["due"]?.string, "d1")
    }
  }

  /// The intent row is written before the owner write. Crash before the owner wrote: nothing is an edit and the view is
  /// shown again. Crash after it wrote: the written value is adopted, no edit. Owner wrote and the person then changed one
  /// field: exactly that field becomes one version.
  func testCrashAroundTheOwnerWriteLeavesNoExtraVersionAndLosesNone() throws {
    let k = try key()
    func prepared(_ name: String) throws -> (CloudBrainAgentsStore, NativeRPCValue, NativeRPCValue) {
      let author = try open("author-" + name), store = try open(name)
      let r0 = try XCTUnwrap(try author.capture(k, local: base, table: table, opId: "r0", device: "a"))
      try store.receive(k, [r0], table: table); try show(store, k)
      let rX = try XCTUnwrap(try author.capture(k, local: base.setting("title", .string("from A")).setting("due", .string("dA")), table: table, opId: "rX", device: "a"))
      try store.receive(k, [rX], table: table)
      let intended = try XCTUnwrap(try store.view(k, table: table)).shown()
      let old = try XCTUnwrap(try store.image(k).value)
      try store.beginShow(k, heads: ["rX"], willStore: intended)
      return (store, old, intended)
    }
    // Before the owner write.
    var (store, old, intended) = try prepared("before")
    store = try open("before")
    XCTAssertNil(try store.capture(k, local: old, table: table, opId: "x1", device: "b"), "The old value is no edit")
    XCTAssertEqual(try store.countsForTesting(k).nodes, 2)
    XCTAssertEqual(try store.view(k, table: table)?.fields["title"]?.string, "from A", "The view still waits to be shown")
    XCTAssertEqual(try show(store, k), intended)
    // After the owner write.
    (store, old, intended) = try prepared("after")
    store = try open("after")
    XCTAssertNil(try store.capture(k, local: intended, table: table, opId: "x2", device: "b"), "The written value is no edit")
    XCTAssertEqual(try store.image(k).value, intended)
    XCTAssertEqual(try store.countsForTesting(k).nodes, 2)
    // After the owner write, with one field then changed by the person.
    (store, old, intended) = try prepared("edited")
    store = try open("edited")
    let changed = intended.setting("priority", .string("p-person"))
    let revision = try XCTUnwrap(try store.capture(k, local: changed, table: table, opId: "x3", device: "b"))
    XCTAssertEqual(revision.version.stamps["priority"]?.op, "x3")
    XCTAssertEqual(revision.version.stamps["title"]?.op, "rX", "The imported title is not re-stamped")
    XCTAssertEqual(revision.version.stamps["due"]?.op, "rX")
    XCTAssertEqual(try store.countsForTesting(k).nodes, 3)
    _ = old
  }

  // MARK: integrity at open

  func testDamagedDatabaseIsMovedAsideAndOpensAsAJoin() throws {
    let k = try key()
    // Garbage in the file.
    var store: CloudBrainAgentsStore? = try open("garbage")
    try store?.capture(k, local: base, table: table, opId: "r0", device: "a")
    let file = try XCTUnwrap(store?.file)
    store = nil
    try Data(repeating: 0x55, count: 8_192).write(to: file)
    store = try open("garbage")
    guard case .replacedDamaged(let aside)? = store?.opening else { return XCTFail("A damaged file is not opened as it is") }
    XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path), "The damaged file is kept aside, not deleted")
    XCTAssertEqual(store?.joining, true, "A replaced database is a join, never 'everything is new'")
    XCTAssertEqual(try store?.countsForTesting(k).nodes, 0)
    // A damaged page inside an otherwise valid file.
    var big: CloudBrainAgentsStore? = try open("page")
    for index in 0..<200 {
      try big?.capture(try key("t\(index)"), local: base.setting("title", .string(String(repeating: "x", count: 200))), table: table, opId: "r\(index)", device: "a")
    }
    let bigFile = try XCTUnwrap(big?.file)
    big = nil
    let handle = try FileHandle(forWritingTo: bigFile)
    try handle.seek(toOffset: 4_096); try handle.write(contentsOf: Data(repeating: 0x55, count: 4_096)); try handle.close()
    big = try open("page")
    guard case .replacedDamaged? = big?.opening else { return XCTFail("A damaged page fails the integrity check") }
    XCTAssertEqual(big?.joining, true)
    // A healthy file opens as it is and is not joining.
    XCTAssertEqual(try open("garbage").opening, .existing)
    XCTAssertEqual(try open("fresh").opening, .fresh)
    XCTAssertEqual(try open("fresh2").joining, false)
  }

  func testTheStoreLivesOnlyInTheAccountFolder() throws {
    XCTAssertThrowsError(try CloudBrainAgentsStore(directory: root.appendingPathComponent("elsewhere"), account: account, clock: .init { 0 })) {
      XCTAssertEqual($0 as? CloudBrainStoreError, .unsafeLocation)
    }
    let store = try open("mode")
    let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(store.file.lastPathComponent, "a2.sqlite")
  }

  // MARK: bounded memory

  /// A record with 5,000 versions: only the head's content is kept and loaded; the versions are small nodes.
  func testThousandsOfVersionsLoadInBoundedMemory() throws {
    let k = try key(), store = try open("thousands")
    let count = 5_000
    var revisions: [CloudBrainMergeRevision] = []
    for index in 0..<count {
      let op = String(format: "v%05d", index), time = Int64(1_000 + index)
      let existsStamp = CloudBrainMergeStamp(time: 1_000, op: "v00000")
      revisions.append(.init(node: .init(opId: op, parents: index == 0 ? [] : [String(format: "v%05d", index - 1)], device: "a", time: time, baseline: false),
        version: .init(table: 1, minTable: 1, baseline: false, fields: ["title": .string("version \(index)"), exists: .bool(true)],
          stamps: ["title": .init(time: time, op: op), exists: existsStamp])))
    }
    for start in stride(from: 0, to: count, by: 500) { try store.receive(k, Array(revisions[start..<start + 500]), table: table) }
    let counts = try store.countsForTesting(k)
    XCTAssertEqual(counts.nodes, count)
    XCTAssertEqual(counts.payloads, 1, "Only the head's content is kept")
    let view = try XCTUnwrap(try store.view(k, table: table))
    XCTAssertEqual(view.fields["title"]?.string, "version 4999")
    let load = store.lastLoad
    XCTAssertEqual(load.nodes, count)
    XCTAssertEqual(load.payloads, 1)
    XCTAssertLessThanOrEqual(load.payloadBytes, 1_024, "Measured: one head's content")
    XCTAssertLessThanOrEqual(load.nodeBytes, 64 * count, "Measured: about 40 bytes per version, bounded at 64")
    // An edit on top keeps one content again once the sync core has it.
    try show(store, k)
    let edit = try XCTUnwrap(try store.capture(k, local: view.shown().setting("due", .string("now")), table: table, opId: "mine", device: "b"))
    XCTAssertEqual(try store.ownUnhanded(limit: 10).map(\.opId), ["mine"])
    try store.markHanded([edit.opId])
    XCTAssertEqual(try store.countsForTesting(k).payloads, 1)
  }

  // MARK: restart

  func testRestartKeepsCarriedConflictsHeldFieldsAndTheImage() throws {
    let k = try key()
    let x = try open("x"), y = try open("y")
    let r0 = try XCTUnwrap(try x.capture(k, local: base, table: table, opId: "r0", device: "x"))
    try y.receive(k, [r0], table: table); try show(y, k)
    let rX = try XCTUnwrap(try x.capture(k, local: base.setting("title", .string("X")), table: table, opId: "rX", device: "x"))
    let rY = try XCTUnwrap(try y.capture(k, local: base.setting("title", .string("Y")), table: table, opId: "rY", device: "y"))
    try x.receive(k, [rY], table: table); try show(x, k)
    let carried = try XCTUnwrap(try x.capture(k, local: try XCTUnwrap(try x.image(k).value).setting("due", .string("later")), table: table, opId: "rD", device: "x"))
    XCTAssertTrue(carried.version.conflicts.contains { $0.field == "title" }, "The other version is carried in the new version")
    try x.setHeld(k, ["permissionMode", "place"])
    let view = try x.view(k, table: table), image = try x.image(k).value, others = try x.otherVersions()
    XCTAssertEqual(others.count, 1)
    _ = rX
    let reopened = try open("x")
    XCTAssertEqual(reopened.opening, .existing)
    XCTAssertEqual(try reopened.view(k, table: table), view)
    XCTAssertEqual(try reopened.view(k, table: table)?.conflicts.map(\.field), ["title"])
    XCTAssertEqual(try reopened.held(k), ["permissionMode", "place"])
    XCTAssertEqual(try reopened.image(k).value, image)
    XCTAssertEqual(try reopened.otherVersions(), others)
    XCTAssertEqual(Set(try reopened.ownUnhanded(limit: 10).map(\.opId)), ["r0", "rX", "rD"], "Own versions not yet handed survive too")
  }

  func testOtherVersionsAreReadInBoundedPages() throws {
    let x = try open("pages-x"), y = try open("pages-y")
    for index in 0..<5 {
      let k = try key("t\(index)")
      let r0 = try XCTUnwrap(try x.capture(k, local: base, table: table, opId: "r0-\(index)", device: "x"))
      try y.receive(k, [r0], table: table); try show(y, k)
      _ = try x.capture(k, local: base.setting("title", .string("X")), table: table, opId: "rX-\(index)", device: "x")
      let rY = try XCTUnwrap(try y.capture(k, local: base.setting("title", .string("Y")), table: table, opId: "rY-\(index)", device: "y"))
      try x.receive(k, [rY], table: table)
    }
    var seen: [CloudBrainOtherVersionRow] = [], after: (CloudBrainRecordKey, String, String)?
    while true {
      let page = try x.otherVersions(after: after, limit: 2)
      XCTAssertLessThanOrEqual(page.count, 2)
      guard let last = page.last else { break }
      seen += page; after = (last.key, last.conflict.field, last.conflict.revision)
    }
    XCTAssertEqual(seen.map(\.key.entity), ["t0", "t1", "t2", "t3", "t4"])
    XCTAssertThrowsError(try x.otherVersions(limit: 0))
  }

  // MARK: the lost database

  /// Only this Mac's database is lost; its owners still hold their records. Composition knows the account already has
  /// Cloud history (lane A's sync store, or the Cloud's coverage) and opens the new database as a join. Whether the
  /// Cloud's versions arrive before or after the owners are captured, the Cloud's values win, this Mac's differing
  /// copies are listed, identical copies make no version, and a record only this Mac had is kept.
  func testLostDatabaseJoinNeverTreatsEverythingAsNew() throws {
    let t1 = try key("t1"), t2 = try key("t2"), t3 = try key("t3")
    let cloud = try open("cloud-author")
    let c1 = try XCTUnwrap(try cloud.capture(t1, local: base, table: table, opId: "c1", device: "a"))
    let c2 = try XCTUnwrap(try cloud.capture(t2, local: base.setting("title", .string("Cloud title")), table: table, opId: "c2", device: "a"))
    let mine2 = base.setting("title", .string("This Mac's title"))
    let mine3 = base.setting("title", .string("Only here"))
    let now = Now(); now.value = 50_000

    // The Cloud's versions are not on this Mac yet: the owners are captured first.
    let early = try open("lost-early", now: now)
    XCTAssertEqual(early.opening, .fresh)
    try early.beginJoin()
    let b1 = try XCTUnwrap(try early.capture(t1, local: base, table: table, opId: "b1", device: "b"))
    let b2 = try XCTUnwrap(try early.capture(t2, local: mine2, table: table, opId: "b2", device: "b"))
    let b3 = try XCTUnwrap(try early.capture(t3, local: mine3, table: table, opId: "b3", device: "b"))
    XCTAssertTrue([b1, b2, b3].allSatisfy { $0.node.baseline && $0.parents.isEmpty }, "Captured as baselines, never as new edits")
    try early.receive(t1, [c1], table: table); try early.receive(t2, [c2], table: table)
    XCTAssertEqual(try early.view(t1, table: table)?.conflicts, [], "An identical copy is no other version")
    XCTAssertEqual(try early.view(t2, table: table)?.fields["title"]?.string, "Cloud title", "The Cloud wins although this Mac's copy is newer")
    XCTAssertEqual(try early.view(t2, table: table)?.conflicts.map { $0.value.string }, ["This Mac's title"], "This Mac's copy is listed")
    XCTAssertEqual(try early.view(t3, table: table)?.fields["title"]?.string, "Only here", "A record only this Mac had is kept")
    try early.finishJoin()
    XCTAssertFalse(early.joining)

    // The Cloud's versions arrive first (lane A pulled them again): identical copies make no version at all.
    let late = try open("lost-late", now: now)
    try late.beginJoin()
    try late.receive(t1, [c1], table: table); try late.receive(t2, [c2], table: table)
    XCTAssertNil(try late.capture(t1, local: base, table: table, opId: "l1", device: "b"), "Identical: adopted, nothing uploaded")
    let l2 = try XCTUnwrap(try late.capture(t2, local: mine2, table: table, opId: "l2", device: "b"))
    XCTAssertTrue(l2.node.baseline)
    XCTAssertEqual(try late.view(t2, table: table)?.fields["title"]?.string, "Cloud title")
    try late.finishJoin()
    // Once joined, ordinary edits are ordinary again.
    try show(late, t2)
    let edit = try XCTUnwrap(try late.capture(t2, local: try XCTUnwrap(try late.image(t2).value).setting("due", .string("d9")), table: table, opId: "l3", device: "b"))
    XCTAssertFalse(edit.node.baseline)
  }

  // MARK: clock and refusals

  func testAVersionMoreThanADayAheadIsRefusedWhole() throws {
    let k = try key(), now = Now(); now.value = 1_000_000
    let store = try open("ahead", now: now)
    func version(_ op: String, _ time: Int64) -> CloudBrainMergeRevision {
      .init(node: .init(opId: op, parents: [], device: "a", time: time, baseline: false), version: .init(table: 1, minTable: 1, baseline: false,
        fields: ["title": .string(op), exists: .bool(true)], stamps: ["title": .init(time: time, op: op), exists: .init(time: time, op: op)]))
    }
    XCTAssertThrowsError(try store.receive(k, [version("ok", 1_000), version("late", 1_000_000 + 86_400_001)], table: table)) {
      XCTAssertEqual($0 as? CloudBrainStoreError, .tooFarAhead("late"))
    }
    XCTAssertEqual(try store.countsForTesting(k).nodes, 0, "Nothing of the delivery is written")
    try store.receive(k, [version("edge", 1_000_000 + 86_400_000)], table: table)
    XCTAssertEqual(try store.countsForTesting(k).nodes, 1, "Exactly a day ahead is accepted")
  }

  func testTheClockIsTheSyncCoresServiceClockWithThisMacsAsFallback() {
    XCTAssertEqual(CloudBrainMergeClock.service({ nil }, local: { 5 }).read(), 5, "Before any commit was answered")
    XCTAssertEqual(CloudBrainMergeClock.service({ 9 }, local: { 5 }).read(), 9)
  }

  // MARK: incomplete history and handing over

  func testARecordWithMissingHistoryWaitsUntilItArrives() throws {
    let k = try key()
    let author = try open("history-author"), store = try open("history")
    let r0 = try XCTUnwrap(try author.capture(k, local: base, table: table, opId: "r0", device: "a"))
    let r1 = try XCTUnwrap(try author.capture(k, local: base.setting("due", .string("d1")), table: table, opId: "r1", device: "a"))
    try store.receive(k, [r1], table: table)
    XCTAssertThrowsError(try store.view(k, table: table)) { XCTAssertEqual($0 as? CloudBrainMergeError, .historyIncomplete(["r0"])) }
    XCTAssertThrowsError(try store.capture(k, local: base, table: table, opId: "x", device: "b"), "Nothing is captured over a record that waits")
    XCTAssertEqual(try store.countsForTesting(k).nodes, 1)
    try store.receive(k, [r0], table: table)
    XCTAssertEqual(try store.view(k, table: table)?.fields["due"]?.string, "d1")
    XCTAssertEqual(try store.countsForTesting(k).payloads, 1, "The late ancestor keeps only its node")
  }

  func testOwnVersionsKeepTheirContentUntilHandedOver() throws {
    let k = try key(), store = try open("handed")
    _ = try XCTUnwrap(try store.capture(k, local: base, table: table, opId: "e1", device: "b"))
    _ = try XCTUnwrap(try store.capture(k, local: base.setting("title", .string("two")), table: table, opId: "e2", device: "b"))
    XCTAssertEqual(try store.ownUnhanded(limit: 10).map(\.opId), ["e1", "e2"], "A quick second edit does not lose the first before upload")
    XCTAssertEqual(try store.countsForTesting(k).payloads, 2)
    try store.markHanded(["e1"])
    XCTAssertEqual(try store.countsForTesting(k).payloads, 1, "Handed and no longer a head: its content is dropped")
    XCTAssertEqual(try store.ownUnhanded(limit: 10).map(\.opId), ["e2"])
    try store.markHanded(["e2"])
    XCTAssertEqual(try store.countsForTesting(k).payloads, 1, "The head keeps its content")
    XCTAssertEqual(try store.ownUnhanded(limit: 10), [])
  }
}
