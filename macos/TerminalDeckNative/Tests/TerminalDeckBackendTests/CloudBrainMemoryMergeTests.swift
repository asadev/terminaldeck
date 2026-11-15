import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Round-2 review, import side: M3 (allow-listed settings), M4 (one convergent winner rule), M6 (every shipped default
/// is a seed; app help files never import) and finding 26 (another Mac's project memory waits until matched).
@Suite("Cloud memory import — convergent merge, seeds of every version, unmatched projects wait")
struct CloudBrainMemoryMergeTests {
    typealias Revision = DeckMemoryCloudMerge.Revision

    /// One whole resource from "another device" as a single valid operation.
    private func makeOp(row: String, key: String, body: Data, store: String = UUID().uuidString.lowercased(),
                        version: String = UUID().uuidString.lowercased(), createdAt: Int64 = 1) throws -> CloudOperation {
        let hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: store, inventoryRow: row, key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        return CloudOperation(v: 1, opId: revision, originDevice: UUID().uuidString.lowercased(), domain: CloudBrainMemoryFormat.domain(row),
                              entityId: BackendCloudBrainMemoryHash.uuid(store + "\n" + key + "\n0"), revision: revision, parents: [], kind: .put,
                              source: .init(sourceId: "memory/" + row, recordId: key, offset: 0, rawHash: hash), createdAt: createdAt,
                              payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
    }
    private func settingOp(owner: String, key: String, value: String, store: String = UUID().uuidString.lowercased()) throws -> CloudOperation {
        let t = try DeckMemoryCloudSchema.table("settings")
        let values: [DeckMemorySQL] = [.text(owner), .text(key), .text(value), .real(1000.5)]
        return try makeOp(row: "I05", key: try DeckMemoryCloudSchema.key(t, values), body: try DeckMemoryCloudSchema.encodeRow(t, values), store: store)
    }
    private func fileOp(_ path: String, _ text: String, row: String = "I01") throws -> CloudOperation {
        try makeOp(row: row, key: "file/" + path, body: Data(text.utf8))
    }
    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func rev(_ version: String, stamp: Int64, baseline: Bool = false, sequence: UInt64? = nil, committedAt: Int64? = nil, opId: String, ancestors: Set<String> = []) -> Revision {
        Revision(storeId: "s", version: version, stamp: stamp, baseline: baseline, sequence: sequence.map { CloudSequence($0) }, committedAt: committedAt, opId: opId, ancestors: ancestors)
    }
    @Test func aCommitTimeNeverChangesTheOrderStampsAreFinal_round4() {
        // Old expectation (round 4): a stamp later than its commit time was ordered at the commit time, so "honest" won.
        // New (Decker, run 6): stamps are final and `winner` never reads the commit time (it is display only), so the
        // order is the same on every Mac whatever commit times it has learned: the later stamp wins.
        let ahead = rev("v1", stamp: 9_000, committedAt: 300, opId: "z"), honest = rev("v2", stamp: 500, committedAt: 600, opId: "a")
        #expect(DeckMemoryCloudMerge.winner(ahead, honest) == ahead && DeckMemoryCloudMerge.winner(honest, ahead) == ahead)
        let unknown = rev("v1", stamp: 9_000, opId: "z")
        #expect(DeckMemoryCloudMerge.winner(unknown, honest).version == DeckMemoryCloudMerge.winner(ahead, honest).version)
    }
    @Test func theWinnerIsTheSameOnEveryMacAndADescendantAlwaysWins_M4() {
        let a = rev("v1", stamp: 500, opId: "b"), b = rev("v2", stamp: 400, opId: "z")
        #expect(DeckMemoryCloudMerge.winner(a, b) == DeckMemoryCloudMerge.winner(b, a))
        #expect(DeckMemoryCloudMerge.winner(a, b) == a)
        let tie = rev("v3", stamp: 500, opId: "c")
        #expect(DeckMemoryCloudMerge.winner(a, tie) == tie && DeckMemoryCloudMerge.winner(tie, a) == tie)
        // A causal descendant wins even with an older stamp.
        let child = rev("v4", stamp: 1, opId: "a", ancestors: ["v1"])
        #expect(DeckMemoryCloudMerge.winner(child, a) == child && DeckMemoryCloudMerge.winner(a, child) == child)
    }
    @Test func aBaselineLosesWhateverTheClocksAndTiesFollowOpIdOnly_M4b() {
        let cloud = rev("v1", stamp: 100, opId: "a"), late = rev("v2", stamp: 9_000_000, baseline: true, opId: "z")
        #expect(DeckMemoryCloudMerge.winner(cloud, late) == cloud && DeckMemoryCloudMerge.winner(late, cloud) == cloud)
        // Between two baselines the older wins.
        let older = rev("v3", stamp: 10, baseline: true, opId: "a")
        #expect(DeckMemoryCloudMerge.winner(older, late) == older && DeckMemoryCloudMerge.winner(late, older) == older)
        // Equal stamps: the larger opId, whatever server sequence either Mac knows (a later sequence does not win).
        let first = rev("v5", stamp: 50, sequence: 7, opId: "z"), second = rev("v6", stamp: 50, sequence: 9, opId: "a")
        #expect(DeckMemoryCloudMerge.winner(first, second) == first && DeckMemoryCloudMerge.winner(second, first) == first)
        let known = rev("v7", stamp: 50, sequence: 3, opId: "m"), unknown = rev("v8", stamp: 50, opId: "n")
        #expect(DeckMemoryCloudMerge.winner(known, unknown) == unknown && DeckMemoryCloudMerge.winner(unknown, known) == unknown)
    }
    @Test func twoMacsApplyingConcurrentEditsInOppositeOrdersShowTheSameValue_M4() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture(), c = try CloudBrainMemoryFixture(), d = try CloudBrainMemoryFixture()
        try await a.store.cloudImportFixtureSet("from A", key: "helper.pause-seconds")
        try await b.store.cloudImportFixtureSet("from B", key: "helper.pause-seconds")
        let fromA = try await a.snapshot("I05").operations, fromB = try await b.snapshot("I05").operations
        try await c.activate("I05"); try await d.activate("I05")
        _ = try await c.apply(fromA, row: "I05"); _ = try await c.apply(fromB, row: "I05")
        _ = try await d.apply(fromB, row: "I05"); _ = try await d.apply(fromA, row: "I05")
        let onC = try await c.store.value("helper.pause-seconds", owner: nil), onD = try await d.store.value("helper.pause-seconds", owner: nil)
        #expect(onC == onD)
        #expect(["from A", "from B"].contains(onC ?? ""))
        // Both versions are kept on both Macs; only which one is shown was decided.
        #expect(try await c.store.cloudMergeFixtureVersions(containing: "helper.pause-seconds") >= 2)
        #expect(try await d.store.cloudMergeFixtureVersions(containing: "helper.pause-seconds") >= 2)
        await a.close(); await b.close(); await c.close(); await d.close()
    }

    @Test func anUnsentLocalEditIsDecidedByTheSameRuleOnceItHasARevision_M4() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.store.cloudImportFixtureSet("from A", key: "tidy.hour")
        let fromA = try await a.snapshot("I05").operations
        try await b.activate("I05")
        try await b.store.cloudImportFixtureSet("from B", key: "tidy.hour") // captured, not exported yet
        let first = try await b.apply(fromA, row: "I05")
        #expect(first.results.contains { $0.status == .keptBoth })
        #expect(try await b.store.value("tidy.hour", owner: nil) == "from B")
        // B's edit gets its revision (recorded inside it), then both Macs decide with the same function.
        let adapter = try b.adapter("I05")
        var cursor: String?, fromB: [CloudOperation] = []
        while let change = try await adapter.localChange(after: cursor) { fromB.append(change.operation); cursor = change.cursor }
        try await b.store.cloudMergeFixtureSettle()
        _ = try await a.apply(fromB, row: "I05")
        let onA = try await a.store.value("tidy.hour", owner: nil), onB = try await b.store.value("tidy.hour", owner: nil)
        #expect(onA == onB)
        await a.close(); await b.close()
    }

    @Test func aNonAllowListedSettingFromAnotherMacIsNeverApplied_M3() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I05")
        let receipt = try await b.apply([try settingOp(owner: "", key: "helper.cursor.s1", value: "42")], row: "I05")
        #expect(try await b.store.value("helper.cursor.s1", owner: nil) == nil)
        #expect(!receipt.results.contains { $0.status == .keptBoth })
        #expect(try await b.store.cloudImportFixtureUnresolved() == 0)
        await b.close()
    }

    @Test func anUntouchedOlderShippedSettingsFileIsASeedAndHelpFilesNeverImport_M6() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.store.start()
        let path = "templates/agent/settings.md"
        let old = DeckMemoryStore.cloudSettingsTextBefore28Oct(DeckMemoryStore.defaultTemplate(.agent))
        #expect(old != DeckMemoryStore.templateSettingsText(DeckMemoryStore.defaultTemplate(.agent)))
        try b.write(path, old)
        try await b.activate("I01")
        let saved = "# Settings for all Agents\n\n- parts: card, notes\n- helper ai: claude\n"
        let receipt = try await b.apply([try fileOp(path, saved)], row: "I01")
        #expect(try text(b.root.appendingPathComponent(path)) == saved)
        #expect(!receipt.results.contains { $0.status == .keptBoth })
        let help = try text(b.root.appendingPathComponent("START-HERE.md"))
        let helpReceipt = try await b.apply([try fileOp("START-HERE.md", "Another Mac's help text.\n")], row: "I01")
        #expect(helpReceipt.results.first?.reason == DeckMemoryStore.cloudAppOwnedExcluded)
        #expect(try text(b.root.appendingPathComponent("START-HERE.md")) == help)
        #expect(!FileManager.default.fileExists(atPath: b.root.appendingPathComponent("archive/cloud-conflicts").path))
        await b.close()
    }

    @Test func anotherMacsProjectMemoryWaitsUntilTheProjectIsMatched_26() async throws {
        let b = try CloudBrainMemoryFixture()
        try b.write("projects/p1/card.md", "Local project card.\n")
        try await b.activate("I01"); try await b.activate("I05")
        let card = try await b.apply([try fileOp("projects/p1/card.md", "The other Mac's project card.\n")], row: "I01")
        #expect(card.results.first?.reason == DeckMemoryStore.cloudWaitingProject)
        let limit = try await b.apply([try settingOp(owner: "project:p1", key: "card.limit", value: "9999")], row: "I05")
        #expect(limit.results.first?.reason == DeckMemoryStore.cloudWaitingProject)
        // Nothing of the local project is touched, and the wait is visible.
        #expect(try text(b.root.appendingPathComponent("projects/p1/card.md")) == "Local project card.\n")
        #expect(try await b.store.value("card.limit", owner: .project("p1")) == nil)
        // Y1 (13 Nov): memory of a project that is on no device of this Mac waits quietly; it is no gap the person
        // must act on (before: readiness not verified while it waited).
        let waitingReadiness = try await b.store.cloudMemoryReadiness()
        #expect(waitingReadiness.verified)
        // The project list says the other Mac's "p1" is this Mac's "p1-abc123": the waiting memory is placed there.
        let placed = try await b.store.cloudSetProjectResolver { id, _ in id == "p1" ? "p1-abc123" : nil }
        #expect(placed == 2)
        #expect(try text(b.root.appendingPathComponent("projects/p1-abc123/card.md")) == "The other Mac's project card.\n")
        #expect(try await b.store.value("card.limit", owner: .project("p1-abc123")) == "9999")
        #expect(try text(b.root.appendingPathComponent("projects/p1/card.md")) == "Local project card.\n")
        #expect(try await b.store.cloudWaitingCount() == 0)
        await b.close()
    }
    @Test func aLateArrivalNeverWinsByArrivingLate_trustRelease() async throws {
        // Sync trust core review, hand-back 1: a change released after its device was trusted reaches the adapter as a
        // LATE arrival (`CloudImportOrigin.late`), at its original position. The memory merge never looks at arrival
        // order or at that mark: a descendant wins, then the stamp the author wrote, then the larger id. So a late
        // arrival that is older by its own stamp does not replace what this Mac shows, and one that is newer does.
        let older = try CloudBrainMemoryFixture(), newer = try CloudBrainMemoryFixture()
        try await older.capture(); try await newer.capture()
        await older.store.cloudSetClock { 1_000 }
        try await older.store.cloudImportFixtureSet("older", key: "tidy.hour")
        let fromOlder = try settingOps(try await localChanges(older, "I05"), "tidy.hour")
        await newer.store.cloudSetClock { 3_000 }
        try await newer.store.cloudImportFixtureSet("newer", key: "tidy.hour")
        let fromNewer = try settingOps(try await localChanges(newer, "I05"), "tidy.hour")
        #expect(fromOlder.count == 1)
        #expect(fromNewer.count == 1)
        func arrive(_ operations: [CloudOperation], on mac: CloudBrainMemoryFixture, position: UInt64, late: Bool) async throws {
            let adapter = try mac.adapter("I05")
            let prepared = try await adapter.validateIncoming(operations, files: [])
            let origin = CloudImportOrigin(deviceId: UUID().uuidString.lowercased(), sequence: CloudSequence(position), committedAt: nil, late: late)
            _ = try await adapter.applyPrepared(prepared, origin: origin)
        }
        // This Mac's current version sits between the two by its stamp.
        let here = try CloudBrainMemoryFixture()
        try await here.capture()
        await here.store.cloudSetClock { 2_000 }
        try await here.store.cloudImportFixtureSet("current", key: "tidy.hour")
        _ = try await localChanges(here, "I05")
        try await arrive(fromOlder, on: here, position: 1, late: true)
        #expect(try await here.store.value("tidy.hour", owner: nil) == "current")
        try await arrive(fromNewer, on: here, position: 2, late: true)
        #expect(try await here.store.value("tidy.hour", owner: nil) == "newer")
        // The other order, newest first in feed order and the older one released afterwards, ends the same way.
        let there = try CloudBrainMemoryFixture()
        try await there.capture()
        await there.store.cloudSetClock { 2_000 }
        try await there.store.cloudImportFixtureSet("current", key: "tidy.hour")
        _ = try await localChanges(there, "I05")
        try await arrive(fromNewer, on: there, position: 2, late: false)
        #expect(try await there.store.value("tidy.hour", owner: nil) == "newer")
        try await arrive(fromOlder, on: there, position: 1, late: true)
        #expect(try await there.store.value("tidy.hour", owner: nil) == "newer")
        await older.close(); await newer.close(); await here.close(); await there.close()
    }
    @Test func leanRuleMergesProjectMemoryOnlyIntoTheSameProjectIdOnThisMac() async throws {
        // Spec AM10 (lean first version): same project id = same project; anything else waits and is listed.
        let b = try CloudBrainMemoryFixture()
        try b.write("projects/p1/card.md", "Local project card.\n") // this Mac has project p1, and no p2
        try await b.activate("I01"); try await b.activate("I05")
        _ = try await b.store.cloudUseLeanProjectRule()
        // The other Mac's memory for p1 is merged into this Mac's p1.
        let same = try await b.apply([try fileOp("projects/p1/playbook.md", "# Playbook\nFrom the other Mac.\n")], row: "I01")
        #expect(same.results.first?.reason != DeckMemoryStore.cloudWaitingProject)
        #expect(try text(b.root.appendingPathComponent("projects/p1/playbook.md")) == "# Playbook\nFrom the other Mac.\n")
        #expect(try text(b.root.appendingPathComponent("projects/p1/card.md")) == "Local project card.\n")
        // Memory for a project this Mac does not have waits: nothing is created, and it is listed in plain words.
        let other = try await b.apply([try fileOp("projects/p2/card.md", "Another project's card.\n")], row: "I01")
        #expect(other.results.first?.reason == DeckMemoryStore.cloudWaitingProject)
        #expect(!FileManager.default.fileExists(atPath: b.root.appendingPathComponent("projects/p2").path))
        // Y1 (13 Nov): memory for a project that is on no device here waits quietly; it is nothing the person has to do.
        let waiting = try await b.store.cloudMemoryReadiness()
        #expect(!waiting.reasons.contains(DeckMemoryCloudLeanProjects.waitingLine(1)))
        #expect(try await b.store.cloudWaitingCount() == 1)
        #expect(DeckMemoryCloudLeanProjects.waitingLine(1) == "1 item of memory is waiting for a project on this Mac.")
        // The project appears on this Mac later: the waiting memory is placed at the next look, by itself.
        try FileManager.default.createDirectory(at: b.root.appendingPathComponent("projects/p2"), withIntermediateDirectories: true)
        let placed = try await b.store.cloudRetryWaitingProjects()
        #expect(placed == 1)
        #expect(try text(b.root.appendingPathComponent("projects/p2/card.md")) == "Another project's card.\n")
        #expect(try await b.store.cloudWaitingCount() == 0)
        // Never by another spelling of the id, and never by name.
        let rule = DeckMemoryCloudLeanProjects.resolver(known: { ["p1"] })
        #expect(rule("p1", "another-store") == "p1")
        #expect(rule("P1", "another-store") == nil)
        #expect(rule("p1-abc123", "another-store") == nil)
        #expect(DeckMemoryCloudLeanProjects.known(memoryRoot: b.root) == ["p1", "p2"])
        await b.close()
    }
    @Test func memoryForAProjectThatArrivedThroughCloudIsMergedOnceItExistsHereWithTheSameId_item7() async throws {
        // Lean scope item 7: lane A2's project rule joins the lean one. The lean rule answers for a project whose
        // memory folder is already on this Mac; the second rule answers, with the SAME id, for a project that
        // arrived through Cloud once the person has chosen a folder for it here. Anything else waits and is listed.
        let b = try CloudBrainMemoryFixture()
        try b.write("projects/p1/card.md", "Local project card.\n")
        try await b.activate("I01"); try await b.activate("I05")
        let chosen = ChosenProjects()
        _ = try await b.store.cloudUseLeanProjectRule(then: { incoming, _ in chosen.has(incoming) ? incoming : nil })
        let same = try await b.apply([try fileOp("projects/p1/playbook.md", "# Playbook\nFrom the other Mac.\n")], row: "I01")
        #expect(same.results.first?.reason != DeckMemoryStore.cloudWaitingProject)
        // p2 arrived through Cloud but has no folder on this Mac yet: its memory waits, untouched, and is counted.
        let other = try await b.apply([try fileOp("projects/p2/card.md", "Another project's card.\n")], row: "I01")
        #expect(other.results.first?.reason == DeckMemoryStore.cloudWaitingProject)
        #expect(try await b.store.cloudWaitingCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: b.root.appendingPathComponent("projects/p2/card.md").path))
        // The person chooses a folder for p2 on this Mac: the waiting memory is placed under the same id.
        chosen.add("p2")
        let placed = try await b.store.cloudRetryWaitingProjects()
        #expect(placed == 1)
        #expect(try text(b.root.appendingPathComponent("projects/p2/card.md")) == "Another project's card.\n")
        #expect(try await b.store.cloudWaitingCount() == 0)
        // A project neither rule knows still waits; and the second rule never renames: another id is never returned
        // for one the lean rule already knows.
        let third = try await b.apply([try fileOp("projects/p3/card.md", "Third project's card.\n")], row: "I01")
        #expect(third.results.first?.reason == DeckMemoryStore.cloudWaitingProject)
        #expect(try await b.store.cloudWaitingCount() == 1)
        // Without a second rule it is the lean rule alone, as before.
        _ = try await b.store.cloudUseLeanProjectRule(then: nil)
        chosen.add("p3")
        let stillWaiting = try await b.store.cloudRetryWaitingProjects()
        #expect(stillWaiting == 0)
        await b.close()
    }
    private final class ChosenProjects: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
        func has(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    }
}


extension CloudBrainMemoryMergeTests {
    private func stampOf(_ op: CloudOperation) throws -> Int64 {
        let part = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
        return try #require(part.stamp.flatMap { Int64($0) })
    }
    private func localChanges(_ f: CloudBrainMemoryFixture, _ row: String) async throws -> [CloudOperation] {
        let adapter = try f.adapter(row)
        var cursor: String?, all: [CloudOperation] = []
        while let change = try await adapter.localChange(after: cursor) { all.append(change.operation); cursor = change.cursor }
        return all
    }
    private func settingOps(_ ops: [CloudOperation], _ key: String) throws -> [CloudOperation] {
        try ops.filter {
            let part = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload))
            return part.key.hasPrefix("row/settings/") && String(decoding: Data(base64Encoded: part.data) ?? Data(), as: UTF8.self).contains(key)
        }
    }

    @Test func aStampIsWrittenOnceAndNeverBeforeItsParent_M4b() async throws {
        let a = try CloudBrainMemoryFixture()
        try await a.capture()
        await a.store.cloudSetClock { 1_000 }
        try await a.store.cloudImportFixtureSet("one", key: "tidy.hour")
        let first = try settingOps(try await localChanges(a, "I05"), "tidy.hour")
        let parentStamp = try stampOf(try #require(first.first))
        await a.store.cloudSetClock { 10 } // a clock that went backwards
        try await a.store.cloudImportFixtureSet("two", key: "tidy.hour")
        let all = try settingOps(try await localChanges(a, "I05"), "tidy.hour")
        let child = try #require(all.last)
        #expect(try stampOf(child) == parentStamp + 1)
        // Re-exporting replays the same bytes; the stamp is never re-made.
        let again = try settingOps(try await localChanges(a, "I05"), "tidy.hour")
        #expect(try again.map { try CloudWire.canonical($0) } == all.map { try CloudWire.canonical($0) })
        await a.close()
    }

    @Test func aJoiningMacsFirstUploadLosesToTheCloudWhateverItsClock_ruleJ() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.store.cloudImportFixtureSet("from A", key: "helper.pause-seconds")
        let fromA = try await a.snapshot("I05").operations
        try await b.store.cloudImportFixtureSet("from B", key: "helper.pause-seconds")
        await b.store.cloudSetClock { 9_000_000_000_000 } // far ahead
        try await b.capture()
        _ = try await b.apply(fromA, row: "I05")          // B now holds a Cloud version of this record
        let fromB = try await b.snapshot("I05").operations // so B's first upload of it is a baseline
        #expect(try settingOps(fromB, "helper.pause-seconds").allSatisfy {
            (try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload))).baseline == true
        })
        try await b.store.cloudMergeFixtureSettle()
        _ = try await a.apply(fromB, row: "I05")
        #expect(try await a.store.value("helper.pause-seconds", owner: nil) == "from A")
        #expect(try await b.store.value("helper.pause-seconds", owner: nil) == "from A")
        await a.close(); await b.close()
    }

    @Test func aRemovedSettingIsNotBroughtBackByAnOlderConcurrentEdit_D1() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture(), c = try CloudBrainMemoryFixture()
        // A's clock moves forward between its two edits, so its removal is clearly the newer capture.
        let clockA = ClockBox(); clockA.value = 5_000_000
        await a.store.cloudSetClock { clockA.value }; await c.store.cloudSetClock { 1 }
        try await a.capture(); try await b.capture(); try await c.capture()
        try await a.store.cloudImportFixtureSet("keep", key: "tidy.hour")
        let v1 = try settingOps(try await localChanges(a, "I05"), "tidy.hour")
        _ = try await b.apply(v1, row: "I05"); _ = try await c.apply(v1, row: "I05")
        // C edits the shared value (older stamp) while A removes it (newer stamp).
        try await c.store.cloudImportFixtureSet("changed on C", key: "tidy.hour")
        let edit = try settingOps(try await localChanges(c, "I05"), "tidy.hour")
        clockA.value = 9_000_000
        try await a.store.cloudImportFixtureSet(nil, key: "tidy.hour")
        let removal = try settingOps(try await localChanges(a, "I05"), "tidy.hour").filter { !v1.contains($0) }
        #expect(!removal.isEmpty)
        _ = try await b.apply(removal, row: "I05")
        #expect(try await b.store.value("tidy.hour", owner: nil) == nil)
        _ = try await b.apply(edit, row: "I05")
        _ = try await a.apply(edit, row: "I05")
        #expect(try await b.store.value("tidy.hour", owner: nil) == nil)
        #expect(try await a.store.value("tidy.hour", owner: nil) == nil)
        await a.close(); await b.close(); await c.close()
    }

    @Test func whileTheServiceClockIsUnknownAStampUsesThisMacsClockAndStaysFinal_round4() async throws {
        // Old expectation (round 4): no version was stamped while the offset was unknown.
        // New (Decker, run 6): the stamp falls back to this Mac's clock and is final; the wiring keeps rows off meanwhile.
        let a = try CloudBrainMemoryFixture()
        try await a.capture()
        let known = ClockBox()
        await a.store.cloudSetClock { known.value }
        #expect(!(await a.store.cloudClockReady()))
        try await a.store.cloudImportFixtureSet("held", key: "tidy.hour")
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let ops = try settingOps(try await localChanges(a, "I05"), "tidy.hour")
        let stamp = try stampOf(try #require(ops.first))
        // Captured just now on this Mac's clock (round 5: capture time, not the row's own `updated`).
        #expect(stamp >= before - 1_000 && stamp <= Int64(Date().timeIntervalSince1970 * 1000) + 1_000)
        // Learning the offset later changes nothing already stamped.
        known.value = 9_000_000_000_000
        #expect(await a.store.cloudClockReady())
        let again = try settingOps(try await localChanges(a, "I05"), "tidy.hour")
        #expect(try stampOf(try #require(again.first)) == stamp)
        await a.close()
    }
    @Test func aTouchedFileIsStampedAtCaptureTimeNotItsModificationTime_round5() async throws {
        // Old expectation (round 4): the note was stamped at its own modification time.
        // New (Decker, round 5): edit and modification times are not trusted (a restore, a copy or `touch` can set them),
        // so the stamp is the moment of capture: for a snapshot-cut file, the cut time.
        let a = try CloudBrainMemoryFixture(); try await a.seed(); try await a.capture()
        let note = a.root.appendingPathComponent("hoot/notes/a.md")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: note.path)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let adapter = try a.adapter("I01")
        var ops: [CloudOperation] = []
        for try await page in await adapter.snapshotPages(cut: .init(snapshotId: UUID().uuidString, at: now, watermarks: [:])) { ops += page.operations }
        let stamp = try stampOf(try #require(try ops.first { try key($0) == "file/hoot/notes/a.md" }))
        #expect(abs(stamp - now) < 60_000)
        #expect(abs(stamp - 1_000_000_000_000) > 86_400_000)
        await a.close()
    }
    @Test func aNewStoreNeverTakesTheClockAStoreThatIsGoneLeftBehind_run14() async throws {
        // Run 14: the stamp clock was kept under the store's address alone. An address is used again once a store is
        // gone, so a new store took a dead store's clock (another test's `{ 1_000 }`) and the test above was stamped
        // at about 0. A store that was given no clock never has one, however many stores came and went before it.
        for _ in 0..<24 {
            try await Self.leaveAClockBehind()
            let fresh = try CloudBrainMemoryFixture()
            let inherited = await fresh.store.cloudClockReady()
            await fresh.close()
            #expect(!inherited)
        }
    }
    private static func leaveAClockBehind() async throws {
        let gone = try CloudBrainMemoryFixture()
        await gone.store.cloudSetClock { 1_000 }
        await gone.close()
    }
    @Test func aSettingWithAFarPastUpdatedIsStampedAtCaptureTime_round5() async throws {
        let a = try CloudBrainMemoryFixture(); try await a.capture()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try await a.store.cloudMergeFixtureSetRaw("restored", key: "tidy.hour", updated: 1_000)
        let ops = try settingOps(try await localChanges(a, "I05"), "tidy.hour")
        let stamp = try stampOf(try #require(ops.first))
        #expect(stamp >= before - 1_000 && stamp <= Int64(Date().timeIntervalSince1970 * 1000) + 1_000)
        #expect(stamp > 1_000_000 * 1_000)
        await a.close()
    }
    @Test func activationWithNoInjectedClockStillSendsStampedMemory_round5() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let outbox = CaptureTestOutbox()
        let activation = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64),
                                                               stateRoot: f.stateRoot, rows: ["I01", "I05"])
        try await activation.start(outbox: outbox)
        let pages = await outbox.firstPages
        #expect(!pages.isEmpty)
        let parts = try pages.flatMap { $0 }.map { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload)) }
        #expect(!parts.isEmpty && parts.allSatisfy { $0.stamp.flatMap { Int64($0) } != nil })
        await activation.stop(); await f.close()
    }

    /// The source store is already closed; the copy and a reopened source get different device ids.
    static func openCopy(of f: CloudBrainMemoryFixture) async throws -> (base: URL, root: URL, store: DeckMemoryStore, stateRoot: URL) {
        let base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("a-copy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: f.base, to: base)
        let root = base.appendingPathComponent("Memory")
        let stateRoot = base.appendingPathComponent("Data/cloud/" + String(repeating: "f", count: 64) + "/memory", isDirectory: true)
        let store = try await DeckMemoryStore.open(root: root, dataRoot: base.appendingPathComponent("Data"), embedder: nil, watch: false,
                                                   now: { Date(timeIntervalSince1970: 1000.125) })
        try await store.cloudResumeCapture(stateRoot: stateRoot)
        return (base, root, store, stateRoot)
    }
    private func pages(_ store: DeckMemoryStore, device: String, snapshots: URL, row: String) async throws -> [CloudOperation] {
        let adapter = try BackendCloudBrainMemory(store: store, deviceId: device, inventoryRow: row, snapshotRoot: snapshots)
        var all: [CloudOperation] = []
        for try await page in await adapter.snapshotPages(cut: .init(snapshotId: UUID().uuidString, at: 1000, watermarks: [:])) { all += page.operations }
        return all
    }
    private func key(_ op: CloudOperation) throws -> String { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload)).key }

    @Test func copiedAppDataKeepsOldBytesAndGivesNewRecordsTheirOwnIds_recordIds() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let before = try await f.snapshot("I01").operations
        await f.store.close()
        let copy = try await Self.openCopy(of: f)
        let source = try await DeckMemoryStore.open(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false,
                                                    now: { Date(timeIntervalSince1970: 1000.125) })
        try await source.cloudResumeCapture(stateRoot: f.stateRoot)
        let deviceA = UUID().uuidString.lowercased(), deviceB = UUID().uuidString.lowercased()
        // (i) A record exported before the copy replays identical bytes on both Macs.
        let onA = try await pages(source, device: deviceA, snapshots: f.snapshotRoot, row: "I01")
        let onB = try await pages(copy.store, device: deviceB, snapshots: copy.stateRoot.appendingPathComponent("snapshots"), row: "I01")
        let card = "file/hoot/card.md"
        let cardA = try onA.filter { try key($0) == card }, cardB = try onB.filter { try key($0) == card }
        #expect(!cardA.isEmpty)
        #expect(try cardA.map { try CloudWire.canonical($0) } == cardB.map { try CloudWire.canonical($0) })
        #expect(try cardA.map { try CloudWire.canonical($0) } == before.filter { try key($0) == card }.map { try CloudWire.canonical($0) })
        // (ii) A record first exported after the copy, on both, gets a different id on each device.
        let note = "hoot/notes/after-copy.md", text = "---\nid: n-after-copy\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# After\nSame words on both.\n"
        for root in [f.root, copy.root] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("hoot/notes"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: root.appendingPathComponent(note))
        }
        _ = try await source.reindex(); _ = try await copy.store.reindex()
        let newA = try await pages(source, device: deviceA, snapshots: f.snapshotRoot, row: "I01").filter { try key($0) == "file/" + note }
        let newB = try await pages(copy.store, device: deviceB, snapshots: copy.stateRoot.appendingPathComponent("snapshots"), row: "I01").filter { try key($0) == "file/" + note }
        #expect(!newA.isEmpty && newA.count == newB.count)
        #expect(Set(newA.map { $0.opId }).isDisjoint(with: Set(newB.map { $0.opId })))
        #expect(newA.allSatisfy { $0.originDevice == deviceA } && newB.allSatisfy { $0.originDevice == deviceB })
        // Applying each Mac's records on the other is "already present": no id conflict, no refusal.
        for (store, device, ops) in [(source, deviceA, newB), (copy.store, deviceB, newA)] {
            let adapter = try BackendCloudBrainMemory(store: store, deviceId: device, inventoryRow: "I01", snapshotRoot: f.snapshotRoot)
            let prepared = try await adapter.validateIncoming(ops, files: [])
            let receipt = try await adapter.applyPrepared(prepared, origin: .init(deviceId: device, sequence: .init(1)))
            #expect(receipt.results.allSatisfy { $0.status == .alreadyPresent })
        }
        await source.close(); await copy.store.close()
        try? FileManager.default.removeItem(at: f.base); try? FileManager.default.removeItem(at: copy.base)
    }
}

/// A service clock that does not know its offset until the test sets one.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64?
    var value: Int64? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

extension DeckMemoryStore {
    /// A shared setting written with an explicit (here far-past) `updated`, as a restore or copy could leave it.
    func cloudMergeFixtureSetRaw(_ value: String, key: String, updated: Double) throws {
        // Bound in column order (key, value, updated). Run 10: the value and the key were bound the wrong way round, so
        // the row written was key "restored" (not a shared setting, rightly not captured) and `tidy.hour` was never set.
        try db.run("INSERT INTO settings(owner,key,value,updated) VALUES ('',?,?,?) ON CONFLICT(owner,key) DO UPDATE SET value=excluded.value,updated=excluded.updated",
                   [.text(key),.text(value),.real(updated)])
    }
    func cloudMergeFixtureSettle() throws {
        try db.transaction {
            try db.run("UPDATE cloud_memory_control SET value='1' WHERE key='importing'")
            defer { try? db.run("UPDATE cloud_memory_control SET value='0' WHERE key='importing'") }
            try cloudSettlePendingMerges()
        }
    }
    func cloudMergeFixtureVersions(containing text: String) throws -> Int {
        try db.rows("SELECT body FROM cloud_memory_versions WHERE resource_key LIKE 'row/%'").filter {
            String(decoding: $0.data(0) ?? Data(), as: UTF8.self).contains(text)
        }.count
    }
}
