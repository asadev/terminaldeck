import Foundation
import XCTest
@testable import TerminalDeckNativeCore

/// Slice 1a: the pure merge of design v2 D1 (revision 4) with the slice-1a review fixes. No owner, no network. Fixture
/// values only. Slice 1b runs every test here again with each Mac's state in its own store
/// (`CloudBrainAgentsMergeThroughStoreTests`): the store's view, image and revisions are then the ones the tests check, and
/// each step asserts they equal the in-memory ones.
class CloudBrainAgentsMergeTests: XCTestCase, @unchecked Sendable {
  /// Set by the slice-1b subclass: each Mac made while it is set keeps its state in a store below this folder.
  nonisolated(unsafe) static var storeRoot: URL?
  final class Now: @unchecked Sendable { var value: Int64 = 0 }

  static let table = CloudBrainMergeTable(domain: "fixture", version: 1, classes: [
    "id": .identity, "title": .shared, "due": .shared, "priority": .shared, "status": .shared, "place": .shared,
    "statusAt": .follows(.partner("status")), "updatedAt": .follows(.touched), "archivedAt": .follows(.newest),
    "notes": .collection(cap: 100), "permissionMode": .widening, "sessionId": .thisMac,
    "decisionRequired": .raise, "tokenBudget": .shrink, "hops": .follows(.newest)])

  /// One Mac. `image` is what its store holds; edits are made from the image, never from the view (review f).
  /// `graph` and `payloads` keep every revision in memory (deliveries to other Macs take them from here); with a store,
  /// the view, the image and new revisions come from the store and must equal the in-memory ones.
  struct Mac {
    static let key = try! CloudBrainRecordKey(domain: "fixture", entity: "t1")
    let device: String
    var graph = CloudBrainMergeGraph()
    var payloads: [String: CloudBrainMergeVersion] = [:]
    private var memoryImage: NativeRPCValue?
    var table = CloudBrainAgentsMergeTests.table
    let store: CloudBrainAgentsStore?
    let now: Now
    init(_ device: String) {
      self.device = device
      let now = Now(); self.now = now
      if let root = CloudBrainAgentsMergeTests.storeRoot {
        do {
          let account = try CloudBrainAgentsAccount(subjectHash: String(repeating: "ab", count: 32), deviceID: UUID().uuidString.lowercased())
          store = try CloudBrainAgentsStore(directory: root.appendingPathComponent("cloud/\(account.subjectHash)/\(device)-\(UUID().uuidString.lowercased())"),
            account: account, clock: .init { now.value })
        } catch { XCTFail("\(device): the store did not open: \(error)"); store = nil }
      } else { store = nil }
    }
    var image: NativeRPCValue? {
      get { memoryImage }
      set {
        memoryImage = newValue
        if let store { XCTAssertNoThrow(try store.setImageForTesting(Self.key, newValue)) }
      }
    }
    /// Only the heads' payloads are handed to the view (must-fix 8).
    func view() throws -> CloudBrainMergeView? {
      let heads = graph.heads
      let memory = heads.isEmpty ? nil : try CloudBrainMerge.view(heads, payloads: payloads.filter { heads.contains($0.key) }, graph: graph, table: table)
      guard let store else { return memory }
      let stored = try store.view(Self.key, table: table)
      XCTAssertEqual(stored, memory, "\(device): the store's view differs from the in-memory one")
      XCTAssertEqual(try store.image(Self.key).value, memoryImage, "\(device): the store's image differs")
      return stored
    }
    var all: [CloudBrainMergeRevision] { graph.nodes.values.compactMap { node in payloads[node.opId].map { CloudBrainMergeRevision(node: node, version: $0) } } }
    private mutating func remember(_ revision: CloudBrainMergeRevision) { graph.add(revision.node); payloads[revision.opId] = revision.version }
    mutating func add(_ revision: CloudBrainMergeRevision) {
      if let store { XCTAssertNoThrow(try store.receive(Self.key, [revision], table: table)) }
      remember(revision)
    }
    /// The store shows the view (as an owner write would): intent, owner write, finish.
    mutating func show() throws {
      let current = try view()
      let shown = current.flatMap { $0.exists ? $0.shown() : nil }
      if let store {
        try store.beginShow(Self.key, heads: current?.heads ?? [], willStore: shown)
        try store.finishShow(Self.key)
      }
      memoryImage = shown
    }
    mutating func receive(_ revisions: [CloudBrainMergeRevision]) throws {
      // The store first: a refused delivery (a version dated too far ahead) changes nothing anywhere.
      if let store { try store.receive(Self.key, revisions, table: table) }
      for revision in revisions { remember(revision) }
      try show()
    }
    @discardableResult
    mutating func edit(_ op: String, at: Int64, baseline: Bool = false, held: Set<String> = [], chosen: Set<String> = [], restore: Bool = false,
                       _ change: (NativeRPCValue?) -> NativeRPCValue?) throws -> CloudBrainMergeRevision? {
      let current = try view()
      let local = change(memoryImage)
      var revision = CloudBrainMerge.revision(over: current, image: baseline ? nil : memoryImage, local: local, held: held, chosen: chosen, restore: restore,
        table: table, opId: op, device: device, clock: .init { at }, baseline: baseline, graph: graph)
      if let store {
        now.value = at
        try store.setHeld(Self.key, held)
        let stored = try store.capture(Self.key, local: local, chosen: chosen, restore: restore, table: table, opId: op, device: device, baseline: baseline)
        XCTAssertEqual(stored, revision, "\(device): the store made a different revision for \(op)")
        revision = stored
      }
      if let revision { remember(revision) }
      memoryImage = local
      return revision
    }
  }
  /// Deterministic generator so a failing schedule reproduces from its seed.
  struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }
  private func record(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
  private func note(_ id: String, at: Double, _ text: String = "note") -> NativeRPCValue { record([("id", .string(id)), ("at", .number(at)), ("text", .string(text))]) }
  private var base: NativeRPCValue {
    record([("id", .string("t1")), ("title", .string("T")), ("due", .string("d0")), ("priority", .string("p0")), ("status", .string("open")),
      ("statusAt", .number(1)), ("place", .string("tasks")), ("notes", .array([])), ("permissionMode", .string("default")),
      ("decisionRequired", .bool(false)), ("tokenBudget", .number(300)), ("hops", .number(0))])
  }
  private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index -> [[T]] in
      var rest = items; let first = rest.remove(at: index)
      return permutations(rest).map { [first] + $0 }
    }
  }
  /// Mac A creates the record; the others receive it.
  private func start(_ others: Int = 3) throws -> (Mac, [Mac], CloudBrainMergeRevision) {
    var a = Mac("mac-a")
    let r0 = try XCTUnwrap(try a.edit("r0", at: 1_000) { _ in self.base })
    var macs: [Mac] = []
    for index in 0..<others { var mac = Mac("mac-\(index)"); try mac.receive([r0]); macs.append(mac) }
    return (a, macs, r0)
  }
  private func set(_ pairs: [(String, NativeRPCValue)]) -> (NativeRPCValue?) -> NativeRPCValue? {
    { image in image.map { stored in pairs.reduce(stored) { $0.setting($1.0, $1.1) } } }
  }

  // MARK: convergence

  /// Three Macs edit across each other; a fourth edits after a partial delivery. Every delivery order gives one view.
  func testThreeMacsWithCrossingEditsConvergeInEveryDeliveryOrder() throws {
    var shownValues: [NativeRPCValue] = []
    for order in permutations(["A", "B", "C"]) {
      var (a, others, r0) = try start()
      var b = others[0], c = others[1], d = others[2]
      let rA = try XCTUnwrap(try a.edit("rA", at: 1_100, set([("title", .string("A title"))])))
      let rB = try XCTUnwrap(try b.edit("rB", at: 1_200, set([("title", .string("B title")), ("due", .string("d1"))])))
      let rC = try XCTUnwrap(try c.edit("rC", at: 1_150, set([("notes", .array([note("n1", at: 1_150, "from C")]))])))
      let byName = ["A": rA, "B": rB, "C": rC]
      try d.receive([byName[order[0]]!])
      let rD = try XCTUnwrap(try d.edit("rD-" + order.joined(), at: 1_300, set([("priority", .string("p1"))])))
      try d.receive(order.dropFirst().map { byName[$0]! })
      let all = [r0, rA, rB, rC, rD]
      for var mac in [a, b, c] { try mac.receive(all); XCTAssertEqual(try mac.view(), try d.view()) }
      let view = try XCTUnwrap(try d.view())
      XCTAssertEqual(view.fields["title"]?.string, "B title")
      XCTAssertEqual(view.fields["due"]?.string, "d1")
      XCTAssertEqual(view.fields["priority"]?.string, "p1")
      XCTAssertEqual(view.collections["notes"]?.map(\.id), ["n1"])
      XCTAssertEqual(view.conflicts.map { [$0.field, $0.revision] }, [["title", "rA"]])
      shownValues.append(view.shown())
    }
    XCTAssertTrue(shownValues.allSatisfy { $0 == shownValues[0] })
  }

  /// Review test 1 (widened in round 2, E): 200 seeded random schedules. Four Macs (one runs a newer app with a field the
  /// others do not know) edit, add and remove notes, remove and restore the record, hold a field, pick "use this one",
  /// and deliver to each other in shuffled order; a fifth Mac joins half-way with its own copy (a baseline). In the end
  /// every Mac holds everything and shows the same view, and nothing is lost: every scalar value (including "exists" and
  /// the unknown field) is shown, listed or replaced by a revision that saw it; follows fields never go below a value
  /// nobody replaced; every note is shown or was removed by a revision that saw it. Failures name their seed.
  func testSeededFiveMacSchedulesConvergeAndLoseNothing() throws {
    let exists = CloudBrainMerge.existsField
    var newerTable = Self.table.classes; newerTable["futureField"] = .shared
    let newer = CloudBrainMergeTable(domain: "fixture", version: 2, classes: newerTable, introduced: ["futureField": 2])
    for seed: UInt64 in 1...200 {
      var rng = SplitMix(state: seed)
      var macs = (0..<5).map { Mac("mac-\($0)") }
      macs[3].table = newer
      let first = try XCTUnwrap(try macs[0].edit("s\(seed)-0", at: 1_000) { _ in self.base })
      for index in 1..<4 { try macs[index].receive([first]) }
      var joined: Set<Int> = [0, 1, 2, 3]
      let joinStep = Int.random(in: 5...20, using: &rng)
      var clock: Int64 = 1_000
      let skew: [Int64] = [0, 40, -25, 90, 15]
      for step in 1...30 {
        clock += Int64.random(in: 1...60, using: &rng)
        let op = "s\(seed)-\(step)"
        if step == joinStep {
          // The joiner pulls from a Mac, then captures its own differing copy as a baseline.
          let from = Int.random(in: 0..<4, using: &rng)
          try macs[4].receive(macs[from].all)
          try macs[4].edit(op + "-join", at: clock + skew[4], baseline: true) { _ in
            self.base.setting("title", .string("joiner's own")).setting("priority", .string("p-join"))
          }
          joined.insert(4); continue
        }
        let who = joined.sorted()[Int.random(in: 0..<joined.count, using: &rng)], at = clock + skew[who], wop = op + "-\(who)"
        switch Int.random(in: 0..<13, using: &rng) {
        case 0, 1, 2:
          let choices: [(String, NativeRPCValue)] = [
            ("title", .string("title-\(step)")), ("due", .string("due-\(step)")), ("priority", .string("p-\(step)")),
            ("status", .string(["open", "done", "blocked"][Int.random(in: 0..<3, using: &rng)])),
            ("permissionMode", .string(["default", "plan", "bypassPermissions"][Int.random(in: 0..<3, using: &rng)])),
            ("decisionRequired", .bool(Bool.random(using: &rng))), ("tokenBudget", .number([0, 100, 200, 500][Int.random(in: 0..<4, using: &rng)])),
            ("hops", .number(Double(Int.random(in: 0...5, using: &rng)))), ("archivedAt", .number(Double(at))),
            ("futureField", .string("future-\(step)"))]
          var pick = choices[Int.random(in: 0..<choices.count, using: &rng)]
          if pick.0 == "futureField", who != 3 { pick = choices[0] }
          var pairs = [pick]
          if pick.0 == "status" { pairs.append(("statusAt", .number(Double(at)))) }
          try macs[who].edit(wop, at: at, set(pairs))
        case 3:
          try macs[who].edit(wop, at: at) { image in
            image.map { $0.setting("notes", .array(($0["notes"].elements ?? []) + [self.note("n\(step)", at: Double(at))])) }
          }
        case 4:
          try macs[who].edit(wop, at: at) { image in
            guard let image, let notes = image["notes"].elements, !notes.isEmpty else { return image }
            return image.setting("notes", .array(Array(notes.dropFirst())))
          }
        case 5:
          if Int.random(in: 0..<3, using: &rng) == 0 { try macs[who].edit(wop, at: at) { _ in nil } }
        case 6:
          // This Mac holds the mode it shows while the person edits the title.
          try macs[who].edit(wop, at: at, held: ["permissionMode"]) { image in
            image.map { $0.setting("permissionMode", .string("plan")).setting("title", .string("held-\(step)")) }
          }
        case 7:
          guard let view = try macs[who].view(), let entry = view.conflicts.first else { continue }
          if entry.field == exists {
            if entry.value.bool == false { try macs[who].edit(wop, at: at) { _ in nil } }
            else { try macs[who].edit(wop, at: at, chosen: [exists], restore: true) { _ in view.shown() } }
          } else {
            try macs[who].edit(wop, at: at, chosen: [entry.field]) { image in
              image.map { entry.value.isNullish ? $0.removing(entry.field) : $0.setting(entry.field, entry.value) }
            }
          }
        case 8:
          if let view = try macs[who].view(), !view.exists { try macs[who].edit(wop, at: at, restore: true) { _ in view.shown() } }
        default:
          let from = joined.sorted()[Int.random(in: 0..<joined.count, using: &rng)]
          guard from != who else { continue }
          let held = macs[who].payloads
          let delivery = macs[from].all.filter { held[$0.opId] == nil }.shuffled(using: &rng)
          try macs[who].receive(delivery)
        }
      }
      let everything = Dictionary(macs.flatMap(\.all).map { ($0.opId, $0) }, uniquingKeysWith: { a, _ in a })
      for index in 0..<5 { try macs[index].receive(Array(everything.values).shuffled(using: &rng)) }
      guard let view = try macs[0].view() else { XCTFail("seed \(seed): no view"); continue }
      for mac in macs.dropFirst() {
        if try mac.view() != view { XCTFail("seed \(seed): \(mac.device) shows a different view") }
      }
      let graph = macs[0].graph
      func replaced(_ field: String, _ revision: String, notCarrying: Bool = false) -> Bool {
        everything.values.contains { other in
          other.version.stamps[field]?.op == other.opId && graph.isAncestor(revision, of: other.opId) &&
            (!notCarrying || !other.version.conflicts.contains { $0.field == field && $0.revision == revision })
        }
      }
      for revision in everything.values {
        for (field, stamp) in revision.version.stamps where stamp.op == revision.opId {
          let value = revision.version.fields[field] ?? .null
          switch Self.table.fieldClass(field) {
          case .follows(.newest)?:
            if !replaced(field, revision.opId), let mine = value.number, let shown = view.fields[field]?.number, shown < mine {
              XCTFail("seed \(seed): \(field) \(mine) from \(revision.opId) went down to \(shown)")
            }
          case .follows?:
            continue
          default:
            if let shown = view.fields[field], CloudValue(shown) == CloudValue(value) { continue }
            if view.conflicts.contains(where: { $0.field == field && $0.revision == revision.opId }) { continue }
            // For "exists", an automatic re-mark that still carries the entry is not a replacement.
            if replaced(field, revision.opId, notCarrying: field == exists) { continue }
            XCTFail("seed \(seed): \(field) = \(value.compact) of \(revision.opId) is neither shown, listed nor replaced by a revision that saw it")
          }
        }
        for (id, element) in revision.version.collections["notes"] ?? [:] where element.stamp.op == revision.opId {
          if view.collections["notes"]?.contains(where: { $0.id == id }) == true { continue }
          let removedBySeer = everything.values.contains { other in
            other.version.removed["notes"]?[id]?.op == other.opId && graph.isAncestor(revision.opId, of: other.opId)
          }
          if !removedBySeer { XCTFail("seed \(seed): note \(id) from \(revision.opId) vanished without a removal that saw it") }
        }
      }
    }
  }

  /// A Mac that never touched the disputed field edits another field later: the disputed field does not flip.
  func testUnrelatedLaterEditCannotFlipADisputedField() throws {
    var (a, others, r0) = try start(2)
    var b = others[0], c = others[1]
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_002, set([("title", .string("Ship notes"))])))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_005, set([("title", .string("Ship release notes"))])))
    try c.receive([rA])
    let rC = try XCTUnwrap(try c.edit("rC", at: 1_030, set([("due", .string("tomorrow"))])))
    var everyone = Mac("mac-x"); try everyone.receive([r0, rA, rB, rC])
    let view = try XCTUnwrap(try everyone.view())
    XCTAssertEqual(view.fields["title"]?.string, "Ship release notes")
    XCTAssertEqual(view.fields["due"]?.string, "tomorrow")
    XCTAssertEqual(view.conflicts.map(\.revision), ["rA"])
  }

  /// C2: an other version carried in a revision clears only for a Mac that had seen it.
  func testCarriedConflictClearsOnlyByAncestry() throws {
    var (a, others, r0) = try start()
    var b = others[0], c = others[1], d = others[2]
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_300, set([("title", .string("A"))])))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_200, set([("title", .string("B"))])))
    try d.receive([rA, rB])
    let rD = try XCTUnwrap(try d.edit("rD", at: 1_400, set([("due", .string("later"))])))
    XCTAssertTrue(rD.version.conflicts.contains { $0.field == "title" && $0.revision == "rB" })
    try c.receive([rA])
    let rC = try XCTUnwrap(try c.edit("rC", at: 1_500, set([("title", .string("C"))])))
    var e = Mac("mac-e"); try e.receive([r0, rA, rB, rD, rC])
    let afterC = try XCTUnwrap(try e.view())
    XCTAssertEqual(afterC.fields["title"]?.string, "C")
    XCTAssertTrue(afterC.conflicts.contains { $0.field == "title" && $0.revision == "rB" }, "C never saw B's value and cannot clear it")
    try e.edit("rE", at: 1_600, set([("title", .string("E"))]))
    XCTAssertFalse(try XCTUnwrap(try e.view()).conflicts.contains { $0.revision == "rB" }, "E had seen it; its edit clears it")
  }

  // MARK: removals and the join rule

  /// Must-fix 2 (review test 2): a removal that lost to an edit stays listed through later unrelated edits, even on a
  /// third Mac; "use this one" clears it.
  func testRemovalThatLostStaysListedUntilChosen() throws {
    var (a, others, _) = try start(2)
    var b = others[0], c = others[1]
    let removal = try XCTUnwrap(try a.edit("rm", at: 2_000) { _ in nil })
    let edit = try XCTUnwrap(try b.edit("ed", at: 1_900, set([("title", .string("Kept"))])))
    try a.receive([edit]); try b.receive([removal]); try c.receive([removal, edit])
    let kept = try XCTUnwrap(try c.view())
    XCTAssertTrue(kept.exists, "The edit beats the removal")
    XCTAssertEqual(kept.conflicts.map { [$0.field, $0.revision] }, [[CloudBrainMerge.existsField, "rm"]])
    let later = try XCTUnwrap(try c.edit("later", at: 2_100, set([("priority", .string("p9"))])))
    try b.receive([later])
    XCTAssertEqual(try b.view()?.conflicts.map(\.revision), ["rm"], "An unrelated edit's re-mark does not clear the removal")
    try b.edit("keep", at: 2_200, chosen: [CloudBrainMerge.existsField]) { $0 }
    XCTAssertEqual(try b.view()?.conflicts.isEmpty, true, "Use this one clears it")
  }

  /// Must-fix 3 (review test 3): a joining Mac's stale copy of a record the Cloud removed does not bring it back.
  func testJoinerCannotBringBackARecordTheCloudRemoved() throws {
    var (a, _, r0) = try start(0)
    let removal = try XCTUnwrap(try a.edit("rm", at: 2_000) { _ in nil })
    var joiner = Mac("mac-j"); try joiner.receive([r0, removal])
    let copy = base.setting("title", .string("Joiner's old copy"))
    let baseline = try XCTUnwrap(try joiner.edit("join", at: 9_000, baseline: true) { _ in copy })
    try a.receive([baseline])
    for mac in [a, joiner] {
      let view = try XCTUnwrap(try mac.view())
      XCTAssertFalse(view.exists, "The Cloud's removal stands")
      XCTAssertTrue(view.conflicts.contains { $0.field == CloudBrainMerge.existsField && $0.revision == "join" }, "The joiner's copy is listed")
    }
  }

  /// C1 / rule J: A uploads first; B joins with a different value. A's value is shown on both, B's is listed.
  func testFirstSignInTheCloudVersionWinsAndTheJoinerIsListed() throws {
    var (a, _, r0) = try start(0)
    var b = Mac("mac-b"); try b.receive([r0])
    let joined = try XCTUnwrap(try b.edit("rBase", at: 999_999, baseline: true) { _ in self.base.setting("title", .string("B's own title")) })
    XCTAssertTrue(joined.parents.isEmpty)
    try a.receive([joined]); try b.receive([])
    for mac in [a, b] {
      let view = try XCTUnwrap(try mac.view())
      XCTAssertEqual(view.fields["title"]?.string, "T")
      XCTAssertEqual(view.conflicts.map { [$0.field, $0.revision, $0.value.string ?? ""] }, [["title", "rBase", "B's own title"]])
    }
    XCTAssertFalse(r0.version.baseline)
  }

  func testBetweenTwoBaselinesTheOlderWins() throws {
    var b = Mac("mac-b"), c = Mac("mac-c")
    let rB = try XCTUnwrap(try b.edit("rB", at: 2_000, baseline: true) { _ in self.record([("title", .string("B"))]) })
    let rC = try XCTUnwrap(try c.edit("rC", at: 3_000, baseline: true) { _ in self.record([("title", .string("C"))]) })
    try b.receive([rC]); try c.receive([rB])
    XCTAssertEqual(try b.view()?.fields["title"]?.string, "B")
    XCTAssertEqual(try c.view(), try b.view())
  }

  func testIdenticalVersionsAndDoubleRemovalsCollapse() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_100, set([("title", .string("Same"))])))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_200, set([("title", .string("Same"))])))
    try a.receive([rB]); try b.receive([rA])
    XCTAssertTrue(try XCTUnwrap(try a.view()).conflicts.isEmpty)
    let removeA = try XCTUnwrap(try a.edit("xA", at: 1_300) { _ in nil })
    let removeB = try XCTUnwrap(try b.edit("xB", at: 1_310) { _ in nil })
    try a.receive([removeB]); try b.receive([removeA])
    let removed = try XCTUnwrap(try a.view())
    XCTAssertFalse(removed.exists)
    XCTAssertTrue(removed.conflicts.isEmpty)
  }

  // MARK: what "changed here" means (must-fix 1)

  /// Review test 5: absent here and absent in the image is not a clear; absent here but stored before is; an owner's
  /// normalised value is no edit; `notes: []` against an image without notes removes nothing.
  func testChangedHereIsJudgedAgainstTheStoredImage() throws {
    var (_, others, _) = try start(1)
    var b = others[0]
    // B's store never kept `priority` and stores the title trimmed.
    b.image = try XCTUnwrap(b.image).removing("priority")
    XCTAssertNil(try b.edit("noop", at: 1_100) { $0 }, "Nothing changed against what B stored")
    let edit = try XCTUnwrap(try b.edit("e1", at: 1_200, set([("due", .string("d1"))])))
    XCTAssertEqual(edit.version.fields["priority"]?.string, "p0", "A field B's store never held is not cleared")
    let cleared = try XCTUnwrap(try b.edit("e2", at: 1_300) { $0?.removing("due") })
    XCTAssertTrue(cleared.version.fields["due"]?.isNullish == true, "A field B had stored and dropped is cleared")
    var c = Mac("mac-c"); c.receive_([edit, cleared], from: b)
    // C's store wrote a tidied value that differs from the view; that is what C stored, not an edit.
    c.image = try XCTUnwrap(try c.view()).shown().setting("title", .string("t (tidied by the owner)"))
    XCTAssertNil(try c.edit("norm", at: 1_400) { $0 }, "An owner's tidy write after an import is not an edit")
    // A record whose image had no notes and now says [] removes nothing.
    var d = Mac("mac-d"); d.receive_([edit, cleared], from: b)
    d.image = try XCTUnwrap(try d.view()).shown().removing("notes")
    let withNotes = try XCTUnwrap(try d.edit("n1", at: 1_500) { $0?.setting("notes", .array([self.note("x", at: 1)])) })
    var e = Mac("mac-e"); e.receive_([edit, cleared, withNotes], from: d)
    e.image = try XCTUnwrap(try e.view()).shown().removing("notes")
    let empty = try e.edit("n2", at: 1_600) { $0?.setting("notes", .array([])) }
    XCTAssertNil(empty, "notes: [] against an image without notes says nothing")
  }

  // MARK: follows fields

  /// Must-fix 4 (review test 4): an archive made alone on one Mac survives a concurrent unrelated edit elsewhere.
  func testLoneFollowsChangeSurvivesAConcurrentEdit() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let archive = try XCTUnwrap(try a.edit("arch", at: 1_100, set([("archivedAt", .number(5_000))])))
    let other = try XCTUnwrap(try b.edit("oth", at: 1_050, set([("due", .string("d9"))])))
    try a.receive([other]); try b.receive([archive])
    XCTAssertEqual(try a.view()?.fields["archivedAt"]?.number, 5_000)
    XCTAssertEqual(try b.view(), try a.view())
  }

  func testFollowsFieldsTravelWithTheirPartnerAndNeverConflict() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_100, set([("status", .string("done")), ("statusAt", .number(5_000)), ("updatedAt", .number(100))])))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_050, set([("status", .string("blocked")), ("statusAt", .number(6_000)), ("updatedAt", .number(200))])))
    try a.receive([rB]); _ = rA
    let view = try XCTUnwrap(try a.view())
    XCTAssertEqual(view.fields["status"]?.string, "done")
    XCTAssertEqual(view.fields["statusAt"]?.number, 5_000)
    XCTAssertEqual(view.fields["updatedAt"]?.number, 200)
    XCTAssertEqual(view.conflicts.map(\.field), ["status"])
  }

  /// Review round 2, D: `statusAt` changed alone on one Mac while another makes an unrelated edit survives.
  func testPartnerFollowerChangedAloneSurvivesAnUnrelatedEdit() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let alone = try XCTUnwrap(try a.edit("sa", at: 1_100, set([("statusAt", .number(7_777))])))
    let other = try XCTUnwrap(try b.edit("ob", at: 1_150, set([("due", .string("d7"))])))
    try a.receive([other]); try b.receive([alone])
    XCTAssertEqual(try a.view()?.fields["statusAt"]?.number, 7_777)
    XCTAssertEqual(try b.view(), try a.view())
  }

  /// Ruling 3 change 4: `decisionRequired` prefers on among concurrent values; the owner never takes "off" from elsewhere.
  func testDecisionRequiredOnlyTurnsOnFromElsewhere() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let on = try XCTUnwrap(try a.edit("on", at: 1_100, set([("decisionRequired", .bool(true))])))
    // B turns it on and then off again, later than A's on and without seeing it.
    let bOn = try XCTUnwrap(try b.edit("b-on", at: 1_050, set([("decisionRequired", .bool(true))])))
    let off = try XCTUnwrap(try b.edit("off", at: 1_200, set([("decisionRequired", .bool(false))])))
    try a.receive([bOn, off]); try b.receive([on])
    XCTAssertEqual(try a.view()?.fields["decisionRequired"]?.bool, true, "On beats a concurrent off, even a later one")
    XCTAssertEqual(try b.view(), try a.view())
    XCTAssertTrue(CloudBrainMerge.mayApply(.raise, before: .bool(false), after: .bool(true)))
    XCTAssertFalse(CloudBrainMerge.mayApply(.raise, before: .bool(true), after: .bool(false)))
    XCTAssertFalse(CloudBrainMerge.mayApply(.raise, before: .bool(true), after: nil))
  }

  /// Ruling 3 change 5: `tokenBudget` takes the smallest positive concurrent value; the owner takes only a smaller limit.
  func testTokenBudgetOnlyGetsSmaller() throws {
    var (a, others, _) = try start(2)
    var b = others[0], c = others[1]
    let larger = try XCTUnwrap(try a.edit("big", at: 1_300, set([("tokenBudget", .number(900))])))
    let smaller = try XCTUnwrap(try b.edit("small", at: 1_100, set([("tokenBudget", .number(100))])))
    let unlimited = try XCTUnwrap(try c.edit("none", at: 1_400, set([("tokenBudget", .number(0))])))
    try a.receive([smaller, unlimited])
    XCTAssertEqual(try a.view()?.fields["tokenBudget"]?.number, 100)
    XCTAssertEqual(Set(try XCTUnwrap(try a.view()).conflicts.map(\.revision)), ["big", "none"], "The others are listed")
    _ = larger
    XCTAssertTrue(CloudBrainMerge.mayApply(.shrink, before: .number(300), after: .number(100)))
    XCTAssertTrue(CloudBrainMerge.mayApply(.shrink, before: .number(0), after: .number(100)), "From no limit to a limit narrows")
    XCTAssertFalse(CloudBrainMerge.mayApply(.shrink, before: .number(300), after: .number(900)))
    XCTAssertFalse(CloudBrainMerge.mayApply(.shrink, before: .number(300), after: .number(0)))
    XCTAssertFalse(CloudBrainMerge.mayApply(.shrink, before: .number(300), after: nil))
  }

  /// Ruling 3 change 6: `hops` takes the largest value and never conflicts.
  func testHopsTakesTheLargest() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let three = try XCTUnwrap(try a.edit("h3", at: 1_100, set([("hops", .number(3))])))
    let one = try XCTUnwrap(try b.edit("h1", at: 1_200, set([("hops", .number(1))])))
    try a.receive([one]); try b.receive([three])
    XCTAssertEqual(try a.view()?.fields["hops"]?.number, 3)
    XCTAssertEqual(try a.view()?.conflicts.isEmpty, true)
  }

  /// Review round 2, C: choosing the "empty" value of a field is a real choice and clears the row.
  func testChoosingEmptyIsARealChoice() throws {
    var (a, others, r0) = try start(1)
    var b = others[0]
    let cleared = try XCTUnwrap(try a.edit("clr", at: 1_100) { $0?.removing("due") })
    let changed = try XCTUnwrap(try b.edit("chg", at: 1_200, set([("due", .string("later"))])))
    try a.receive([changed]); try b.receive([cleared])
    XCTAssertEqual(try a.view()?.conflicts.map { [$0.field, $0.revision] }, [["due", "clr"]])
    try a.edit("pick", at: 1_300, chosen: ["due"]) { $0?.removing("due") }
    let view = try XCTUnwrap(try a.view())
    XCTAssertTrue(view.fields["due"]?.isNullish == true)
    XCTAssertTrue(view.conflicts.isEmpty)
    _ = r0
  }

  /// Review round 2, B: a parent dated at the largest possible time does not overflow.
  func testParentAtTheLargestTimeDoesNotOverflow() throws {
    let far = CloudBrainMergeRevision(node: .init(opId: "far", parents: [], device: "x", time: .max, baseline: false), version: .init(table: 1, minTable: 1, baseline: false,
      fields: ["title": .string("T"), CloudBrainMerge.existsField: .bool(true)],
      stamps: ["title": .init(time: .max, op: "far"), CloudBrainMerge.existsField: .init(time: .max, op: "far")]))
    var mac = Mac("m"); try mac.receive([far])
    let child = try XCTUnwrap(try mac.edit("child", at: 1_000, set([("title", .string("U"))])))
    XCTAssertEqual(child.time, .max)
  }

  /// A change to `updatedAt` alone (touched by every write) is no revision.
  func testTouchedFieldAloneMakesNoRevision() throws {
    var (_, others, _) = try start(1)
    var b = others[0]
    XCTAssertNil(try b.edit("touch", at: 1_100, set([("updatedAt", .number(9_999))])))
  }

  // MARK: the clock (must-fix 5)

  /// Stamps are final when written: a Mac that got the history through a checkpoint and one that got the feed pick the
  /// same winner, and an edit made before the author's acknowledgement freezes nothing. A fast local clock is corrected
  /// by the offset learned from the service.
  func testStampsAreFinalOnEveryDeliveryPath() throws {
    let year: Int64 = 31_536_000_000
    var (a, others, r0) = try start(1)
    var fast = others[0]
    let fastClock = CloudBrainMergeClock.corrected(offset: -year) { 1_500 + year }
    let rFast = try XCTUnwrap(CloudBrainMerge.revision(over: try fast.view(), image: fast.image, local: fast.image?.setting("title", .string("fast")),
      table: Self.table, opId: "rFast", device: "fast", clock: fastClock, baseline: false, graph: fast.graph))
    fast.add(rFast); fast.image = fast.image?.setting("title", .string("fast"))
    XCTAssertEqual(rFast.time, 1_500, "The corrected clock, not the raw one")
    // Before anything is acknowledged the fast Mac edits another field: its title stamp is copied, not re-decided.
    let rFast2 = try XCTUnwrap(try fast.edit("rFast2", at: 1_510, set([("due", .string("x"))])))
    let rA = try XCTUnwrap(try a.edit("rA", at: 2_000, set([("title", .string("from A"))])))
    var feed = Mac("feed"); try feed.receive([r0, rFast, rFast2, rA])
    var checkpoint = Mac("checkpoint"); try checkpoint.receive([rA, rFast2, r0, rFast])
    try fast.receive([rA])
    XCTAssertEqual(try feed.view()?.fields["title"]?.string, "from A")
    XCTAssertEqual(try checkpoint.view(), try feed.view())
    XCTAssertEqual(try fast.view(), try feed.view())
    let child = try XCTUnwrap(try fast.edit("child", at: 100, set([("priority", .string("x"))])))
    XCTAssertGreaterThan(child.time, rA.time, "Never earlier than a parent")
  }

  // MARK: incomplete history, bad numbers, small nodes (must-fixes 6, 7, 8)

  /// Review test 7: with an ancestor missing the view reports it instead of differing.
  func testMissingHistoryIsReportedNotGuessed() throws {
    var (a, others, r0) = try start(0)
    _ = others
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_100, set([("title", .string("A"))])))
    var partial = CloudBrainMergeGraph([rA.node])
    XCTAssertThrowsError(try CloudBrainMerge.view(partial.heads, payloads: [rA.opId: rA.version], graph: partial, table: Self.table)) { error in
      XCTAssertEqual(error as? CloudBrainMergeError, .historyIncomplete(["r0"]))
    }
    partial.add(r0.node)
    XCTAssertNoThrow(try CloudBrainMerge.view(partial.heads, payloads: [rA.opId: rA.version], graph: partial, table: Self.table))
    XCTAssertThrowsError(try CloudBrainMerge.view(["rA"], payloads: [:], graph: partial, table: Self.table), "A head without its payload waits")
  }

  /// Review test 8: out-of-range or non-whole numbers from another device are refused, never a crash.
  func testOutOfRangeNumbersAreRefused() throws {
    let (a, _, _) = try start(0)
    let good = try XCTUnwrap(a.payloads["r0"]).payload()
    for bad in [good.setting("table", .number(1e300)), good.setting("minTable", .number(.infinity)),
                good.setting("stamps", good["stamps"].setting("title", .array([.number(1e300), .string("r0")]))),
                good.setting("table", .number(1.5))] {
      XCTAssertThrowsError(try CloudBrainMergeVersion(payload: bad)) { XCTAssertEqual($0 as? CloudBrainMergeError, .invalidPayload) }
    }
    XCTAssertEqual(CloudBrainMerge.orderKey(note("x", at: 1e300), id: "x", stamp: .init(time: 7, op: "o")).0, 7)
  }

  /// Pins the reading behind INT's 2bb4e897 failure: a version that is not a head needs only its node. With several
  /// heads, carried other versions and stamps that name old versions, a view given the nodes of the whole history but the
  /// payloads of the heads alone never reports "history incomplete"; only a missing node does.
  func testNonHeadVersionsNeedOnlyTheirNodes() throws {
    var (a, others, r0) = try start(2)
    var b = others[0], c = others[1]
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_100, set([("title", .string("X"))])))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_200, set([("title", .string("Y"))])))
    try c.receive([rA, rB])
    let rC = try XCTUnwrap(try c.edit("rC", at: 1_300, set([("due", .string("carried"))])))
    let rD = try XCTUnwrap(try a.edit("rD", at: 1_400, set([("priority", .string("p2"))])))
    let all = [r0, rA, rB, rC, rD]
    let graph = CloudBrainMergeGraph(all.map(\.node))
    let heads = graph.heads
    XCTAssertEqual(heads, ["rC", "rD"])
    let headPayloads = Dictionary(uniqueKeysWithValues: all.filter { heads.contains($0.opId) }.map { ($0.opId, $0.version) })
    let view = try CloudBrainMerge.view(heads, payloads: headPayloads, graph: graph, table: Self.table)
    XCTAssertEqual(view.fields["title"]?.string, "Y")
    XCTAssertEqual(view.conflicts.map { [$0.field, $0.revision] }, [["title", "rA"]], "The carried entry names rA, whose payload is not given")
    XCTAssertEqual(try CloudBrainMerge.view(heads, payloads: Dictionary(uniqueKeysWithValues: all.map { ($0.opId, $0.version) }), graph: graph, table: Self.table), view,
      "Extra payloads change nothing")
    let withoutRoot = CloudBrainMergeGraph(all.filter { $0.opId != "r0" }.map(\.node))
    XCTAssertThrowsError(try CloudBrainMerge.view(heads, payloads: headPayloads, graph: withoutRoot, table: Self.table)) {
      XCTAssertEqual($0 as? CloudBrainMergeError, .historyIncomplete(["r0"]), "Only a missing node makes the record wait")
    }
  }

  /// Must-fix 8: a view needs the heads' payloads only; older revisions are small nodes.
  func testViewNeedsOnlyHeadPayloads() throws {
    var (a, _, _) = try start(0)
    for step in 1...20 { try a.edit("e\(step)", at: 1_000 + Int64(step) * 10, set([("due", .string("d\(step)"))])) }
    let heads = a.graph.heads
    XCTAssertEqual(heads, ["e20"])
    let view = try CloudBrainMerge.view(heads, payloads: a.payloads.filter { heads.contains($0.key) }, graph: a.graph, table: Self.table)
    XCTAssertEqual(view.fields["due"]?.string, "d20")
  }

  // MARK: collections

  func testCollectionUnionRemovalOrderAndTheNoteCap() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let seed = try XCTUnwrap(try a.edit("seed", at: 1_050, set([("notes", .array([note("n0", at: 10)]))])))
    try b.receive([seed])
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_100, set([("notes", .array([note("n1", at: 20, "first")]))])))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_090) { $0?.setting("notes", .array([self.note("n0", at: 10), self.note("n2", at: 15), self.record([("text", .string("no id")), ("at", .number(5))])])) })
    try a.receive([rB]); try b.receive([rA])
    let view = try XCTUnwrap(try a.view())
    let ids = try XCTUnwrap(view.collections["notes"]).map(\.id)
    XCTAssertEqual(ids.filter { !$0.hasPrefix("h:") }, ["n2", "n1"])
    XCTAssertEqual(ids.first?.hasPrefix("h:"), true)
    XCTAssertTrue(view.conflicts.isEmpty)
    XCTAssertEqual(try b.view(), view)
    // The owner keeps the newest 100: an oldest note dropped by that cap is not a removal; one inside the newest 100 is.
    var c = Mac("mac-c")
    let full = (1...100).map { note("c\($0)", at: Double($0)) }
    try c.edit("c0", at: 5_000) { _ in self.record([("title", .string("cap")), ("notes", .array(full))]) }
    let capped = try XCTUnwrap(try c.edit("c1", at: 5_100) { $0?.setting("notes", .array(Array(full.dropFirst()) + [self.note("c101", at: 101)])) })
    XCTAssertNil(capped.version.removed["notes"]?["c1"], "Dropped by the cap, not removed")
    XCTAssertEqual(capped.version.collections["notes"]?.count, 100, "The shared set keeps the newest 100")
    let removal = try XCTUnwrap(try c.edit("c2", at: 5_200) { $0.map { v in v.setting("notes", .array((v["notes"].elements ?? []).filter { $0["id"].string != "c50" })) } })
    XCTAssertNotNil(removal.version.removed["notes"]?["c50"])
  }

  /// Review test 9: edited on one Mac and removed on another (kept), removed by a Mac that saw the edit (gone), then added again.
  func testElementEditRemovalAndReAdd() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let add = try XCTUnwrap(try a.edit("add", at: 1_100, set([("notes", .array([note("n", at: 1, "v1")]))])))
    try b.receive([add])
    let edit = try XCTUnwrap(try a.edit("edit", at: 1_200, set([("notes", .array([note("n", at: 1, "v2")]))])))
    let remove = try XCTUnwrap(try b.edit("remove", at: 1_300, set([("notes", .array([]))])))
    try a.receive([remove]); try b.receive([edit])
    XCTAssertEqual(try a.view()?.collections["notes"]?.map { $0.value["text"].string }, ["v2"], "A concurrent edit beats the removal")
    let removeSeen = try XCTUnwrap(try a.edit("remove2", at: 1_400, set([("notes", .array([]))])))
    try b.receive([removeSeen])
    XCTAssertEqual(try b.view()?.collections["notes"]?.isEmpty, true, "Removed by a Mac that saw the edit")
    try b.edit("readd", at: 1_500, set([("notes", .array([note("n", at: 1, "v3")]))]))
    XCTAssertEqual(try b.view()?.collections["notes"]?.map { $0.value["text"].string }, ["v3"])
  }

  // MARK: unknown fields, holds, this-Mac-only

  func testUnknownNewerFieldsAreCarriedThrough() throws {
    let newer = CloudBrainMergeRevision(node: .init(opId: "n0", parents: [], device: "mac-new", time: 1_000, baseline: false), version: .init(table: 2, minTable: 2, baseline: false,
      fields: ["title": .string("T"), "futureField": .string("x"), CloudBrainMerge.existsField: .bool(true)],
      stamps: ["title": .init(time: 1_000, op: "n0"), "futureField": .init(time: 1_000, op: "n0"), CloudBrainMerge.existsField: .init(time: 1_000, op: "n0")],
      collections: ["futureList": ["e1": .init(id: "e1", value: .string("kept"), stamp: .init(time: 1_000, op: "n0"))]]))
    var old = Mac("mac-old"); try old.receive([newer])
    old.image = try XCTUnwrap(old.image).removing("futureField")
    let edit = try XCTUnwrap(try old.edit("o1", at: 2_000, set([("title", .string("Edited on the older Mac"))])))
    XCTAssertEqual(edit.version.fields["futureField"]?.string, "x")
    XCTAssertEqual(edit.version.stamps["futureField"]?.op, "n0")
    XCTAssertEqual(edit.version.collections["futureList"]?["e1"]?.value.string, "kept")
    XCTAssertEqual(edit.version.minTable, 2)
  }

  /// Review test 10: two heads differing in a field the older app does not know, merged and written on by the older app.
  func testOlderAppMergesHeadsThatDifferInAnUnknownField() throws {
    func newer(_ op: String, _ value: String, at: Int64) -> CloudBrainMergeRevision {
      .init(node: .init(opId: op, parents: ["n0"], device: op, time: at, baseline: false), version: .init(table: 2, minTable: 2, baseline: false,
        fields: ["title": .string("T"), "futureField": .string(value), CloudBrainMerge.existsField: .bool(true)],
        stamps: ["title": .init(time: 1_000, op: "n0"), "futureField": .init(time: at, op: op), CloudBrainMerge.existsField: .init(time: 1_000, op: "n0")]))
    }
    let root = CloudBrainMergeRevision(node: .init(opId: "n0", parents: [], device: "n", time: 1_000, baseline: false), version: .init(table: 2, minTable: 2, baseline: false,
      fields: ["title": .string("T"), "futureField": .string("x"), CloudBrainMerge.existsField: .bool(true)],
      stamps: ["title": .init(time: 1_000, op: "n0"), "futureField": .init(time: 1_000, op: "n0"), CloudBrainMerge.existsField: .init(time: 1_000, op: "n0")]))
    var old = Mac("mac-old"); try old.receive([root, newer("n1", "one", at: 1_100), newer("n2", "two", at: 1_200)])
    let view = try XCTUnwrap(try old.view())
    XCTAssertEqual(view.fields["futureField"]?.string, "two")
    XCTAssertEqual(view.conflicts.map { [$0.field, $0.revision] }, [["futureField", "n1"]])
    let edit = try XCTUnwrap(try old.edit("o1", at: 1_300, set([("title", .string("old app"))])))
    XCTAssertEqual(edit.version.fields["futureField"]?.string, "two")
    XCTAssertTrue(edit.version.conflicts.contains { $0.field == "futureField" && $0.revision == "n1" }, "Carried, not dropped")
  }

  /// C3: one hold set. A held widening and a held Trash move are sent with the view's value, never undone here.
  func testHeldFieldsAreNeverUndoneByTheMacThatHoldsThem() throws {
    var (a, others, _) = try start(2)
    var b = others[0], c = others[1]
    let widen = try XCTUnwrap(try a.edit("wA", at: 1_100, set([("permissionMode", .string("bypassPermissions")), ("place", .string("trash"))])))
    try b.receive([widen]); try c.receive([widen])
    // B holds both: its store keeps its own narrower mode and the live task; the person edits the title on B.
    b.image = try XCTUnwrap(b.image).setting("permissionMode", .string("default")).setting("place", .string("tasks"))
    let edit = try XCTUnwrap(try b.edit("eB", at: 1_200, held: ["permissionMode", "place"], set([("title", .string("Edited on B"))])))
    XCTAssertEqual(edit.version.fields["permissionMode"]?.string, "bypassPermissions")
    XCTAssertEqual(edit.version.stamps["permissionMode"]?.op, "wA")
    XCTAssertEqual(edit.version.fields["place"]?.string, "trash")
    try a.receive([edit])
    XCTAssertEqual(try a.view()?.fields["permissionMode"]?.string, "bypassPermissions")
    // Without the hold, a store that writes its own narrower value would undo it.
    let unheld = try XCTUnwrap(try c.edit("eC", at: 1_200, set([("permissionMode", .string("default"))])))
    XCTAssertEqual(unheld.version.fields["permissionMode"]?.string, "default")
  }

  func testThisMacOnlyFieldsNeverTravel() throws {
    var (a, _, _) = try start(0)
    XCTAssertNil(try a.edit("s", at: 2_000, set([("sessionId", .string("live"))])))
    let edit = try XCTUnwrap(try a.edit("e", at: 2_100, set([("sessionId", .string("other")), ("title", .string("x"))])))
    XCTAssertNil(edit.version.fields["sessionId"])
  }

  // MARK: decisions 5, 6, 7 (review test 11)

  /// Decision 5: an other version disappears when the shown value equals it.
  func testOtherVersionClearsWhenTheShownValueEqualsIt() throws {
    var (a, others, r0) = try start(2)
    var b = others[0], c = others[1]
    let rA = try XCTUnwrap(try a.edit("rA", at: 1_100, set([("title", .string("X"))])))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_200, set([("title", .string("Y"))])))
    try c.receive([rA])
    let rC = try XCTUnwrap(try c.edit("rC", at: 1_300, set([("title", .string("Y"))])))
    // x must hold the whole history: r0 is the parent of every edit (INT 2bb4e897: the set-up left it out).
    var x = Mac("x"); try x.receive([r0, rA, rB, rC])
    XCTAssertEqual(try x.view()?.fields["title"]?.string, "Y")
    XCTAssertEqual(try x.view()?.conflicts.map(\.revision), [], "A's value was replaced by C, who saw it; B's equals the shown value")
  }

  /// Decision 6: a follows field with nothing to compare takes the lowest head id (last fallback only).
  func testFollowsFieldWithNothingToCompareTakesTheLowestHead() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let rA = try XCTUnwrap(try a.edit("zz", at: 1_100, set([("archivedAt", .string("not a number")), ("due", .string("1"))])))
    let rB = try XCTUnwrap(try b.edit("aa", at: 1_100, set([("archivedAt", .string("also text")), ("due", .string("2"))])))
    try a.receive([rB]); try b.receive([rA])
    XCTAssertEqual(try a.view()?.fields["archivedAt"]?.string, "also text")
    XCTAssertEqual(try b.view(), try a.view())
  }

  /// Decision 7: when several removals of one element exist, the latest is kept as the removal record.
  func testLatestRemovalIsKeptAsTheRemovalRecord() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    let add = try XCTUnwrap(try a.edit("add", at: 1_100, set([("notes", .array([note("n", at: 1)]))])))
    try b.receive([add])
    let r1 = try XCTUnwrap(try a.edit("rmA", at: 1_200, set([("notes", .array([]))])))
    let r2 = try XCTUnwrap(try b.edit("rmB", at: 1_300, set([("notes", .array([]))])))
    try a.receive([r2]); try b.receive([r1])
    XCTAssertEqual(try a.view()?.removed["notes"]?["n"]?.op, "rmB")
  }

  func testPayloadRoundTrips() throws {
    var (a, others, _) = try start(1)
    var b = others[0]
    try a.edit("rA", at: 1_100, set([("title", .string("A")), ("notes", .array([note("n1", at: 1)]))]))
    let rB = try XCTUnwrap(try b.edit("rB", at: 1_200, set([("title", .string("B"))])))
    try a.receive([rB])
    let carried = try XCTUnwrap(try a.edit("rC", at: 1_300, set([("due", .string("z"))])))
    let payload = carried.version.payload()
    XCTAssertEqual(try CloudBrainMergeVersion(payload: payload), carried.version)
    XCTAssertEqual(try CloudBrainMergeVersion(payload: payload).payload(), payload)
    XCTAssertFalse(carried.version.conflicts.isEmpty)
  }
}

private extension CloudBrainAgentsMergeTests.Mac {
  /// Receive another Mac's revisions without showing the view (the test then sets the stored image itself).
  mutating func receive_(_ revisions: [CloudBrainMergeRevision], from other: CloudBrainAgentsMergeTests.Mac) {
    for revision in other.all { add(revision) }
    for revision in revisions { add(revision) }
  }
}

extension CloudBrainAgentsMergeTests {
  /// Fixture folder for slice-1b stores: only under ~/Deck Dev/notes/cloud-test-20261112/a2.
  static func fixtureFolder(_ name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/a2/\(name)-\(UUID().uuidString.lowercased())")
  }
}
