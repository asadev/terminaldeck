import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The old moves/cleanup gate stays in place, while explicit Everywhere deletes travel compatibly even when it is
/// closed. Archived-note settling sends only proven moves, with no delay between batches. File absences are local
/// marks, incoming deletes apply into the Bin immediately, and revision ancestry protects offline edits.
/// Real memory stores on scratch folders,
/// two and three Macs exchanging records through the existing fixture; a byte-for-byte check that every text that
/// existed before still exists somewhere after. Written unbuilt; the integrator runs them.
@Suite("Cloud memory — one rule, phase 2")
struct CloudMemoryPhase2Tests {
    private static let note = "hoot/notes/a.md"
    private static let head = "---\nid: n-fixture-a\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Note\n"
    private func text(_ f: CloudBrainMemoryFixture, _ path: String) -> String? { try? String(contentsOf: f.root.appendingPathComponent(path), encoding: .utf8) }
    private func exists(_ f: CloudBrainMemoryFixture, _ path: String) -> Bool { FileManager.default.fileExists(atPath: f.root.appendingPathComponent(path).path) }

    /// What each Mac has already handed on, per row: an exchange sends only what is new (as the pump does).
    final class Cursors: @unchecked Sendable {
        private let lock = NSLock()
        private var at: [String: String] = [:]
        func get(_ key: String) -> String? { lock.withLock { at[key] } }
        func set(_ key: String, _ value: String?) { lock.withLock { at[key] = value } }
    }
    private func newChanges(_ f: CloudBrainMemoryFixture, _ row: String, _ cursors: Cursors) async throws -> [CloudOperation] {
        let adapter = try f.adapter(row), key = f.deviceId + "|" + row
        var cursor = cursors.get(key), out: [CloudOperation] = [], seen = Set<String>()
        while let change = try await adapter.localChange(after: cursor) {
            if seen.insert(change.operation.opId).inserted { out.append(change.operation) }
            cursor = change.cursor
        }
        cursors.set(key, cursor)
        return out
    }
    /// Every Mac hands what is new to every other Mac (settings first, then files).
    private func exchange(_ macs: [CloudBrainMemoryFixture], _ cursors: Cursors, rows: [String] = ["I05", "I06", "I01"]) async throws {
        for row in rows {
            var sent: [(from: String, ops: [CloudOperation])] = []
            for f in macs { sent.append((f.deviceId, try await newChanges(f, row, cursors))) }
            for (from, ops) in sent where !ops.isEmpty {
                for f in macs where f.deviceId != from { _ = try await f.apply(ops, row: row) }
            }
        }
    }
    /// `count` Macs holding the seeded memory, the others joined from the first one's copy; every Mac on one service
    /// clock; sending decided by the account (never forced).
    private func macs(_ count: Int, clock: OneRuleClock) async throws -> [CloudBrainMemoryFixture] {
        let first = try CloudBrainMemoryFixture()
        try await first.seed()
        var all = [first]
        if count == 1 { for row in ["I01", "I05", "I06"] { _ = try await first.snapshot(row) } }   // capture on
        for _ in 1..<count {
            let other = try CloudBrainMemoryFixture()
            try await other.store.start()
            for row in ["I01", "I05", "I06"] {
                try await other.activate(row)
                _ = try await other.apply(try await first.snapshot(row).operations, row: row)
            }
            all.append(other)
        }
        for f in all {
            await f.store.cloudSetDevice(f.deviceId)
            await f.store.cloudSetClock { clock.now }
            await f.store.cloudSetOneRuleSending(nil)
            try await f.store.oneRuleFixtureCaptureAll()
        }
        let ids = all.map(\.deviceId)
        for f in all { await f.store.cloudOneRuleSetAccountMacs(ids) }
        return all
    }
    /// Every Mac takes a step (it announces it understands), the settings travel, and every Mac takes `steps` more:
    /// the phase-2 safety copy is made once every Mac understands (review blocker 4), then the settlings run.
    private func switchOn(_ macs: [CloudBrainMemoryFixture], _ cursors: Cursors, steps: Int = 1) async throws {
        for f in macs { _ = try await f.store.cloudOneRuleStep() }
        try await exchange(macs, cursors, rows: ["I05"])
        for _ in 0..<steps { for f in macs { _ = try await f.store.cloudOneRuleStep() } }
    }
    private func note(_ name: String, _ words: String) -> String {
        "---\nid: n-\(name)\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# \(name)\n\(words)\n"
    }
    /// Notes written on `a`, indexed, captured and handed to every Mac.
    private func shared(_ paths: [String], on a: CloudBrainMemoryFixture, _ all: [CloudBrainMemoryFixture], _ cursors: Cursors) async throws {
        for path in paths { try a.write(path, note(String(path.split(separator: "/").last!.dropLast(3)), "Words of " + path + ".")) }
        _ = try await a.store.reindex()
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot"])
        try await exchange(all, cursors)
    }
    private func sends(_ f: CloudBrainMemoryFixture) async -> Bool { await f.store.cloudOneRuleSends() }
    private func off(_ f: CloudBrainMemoryFixture) async -> Bool { !(await f.store.cloudOneRuleSends()) }
    private func allTexts(_ macs: [CloudBrainMemoryFixture]) async throws -> Set<String> {
        var out = Set<String>()
        for f in macs { out.formUnion(try await f.store.oneRuleFixtureAllTexts()) }
        return out
    }
    private func markerTexts(_ ops: [CloudOperation]) -> [String] {
        ops.compactMap { op in
            guard let part = try? JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload)),
                  let data = Data(base64Encoded: part.data), DeckMemoryRemoval.parse(data) != nil else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
    private func removalOps(_ ops: [CloudOperation]) -> [DeckMemoryRemoval] {
        ops.compactMap { op in
            guard let part = try? JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload)) else { return nil }
            return Data(base64Encoded: part.data).flatMap(DeckMemoryRemoval.parse)
        }
    }

    // 1 + 2. Off until every Mac announced freshly; a stale phase-1 "1" never counts; off again when one stops
    // renewing or announces an older format; on again when it renews. An unknown list, or a list without this Mac: off.
    @Test func sendingIsOnOnlyWhileEveryMacFreshlyUnderstands() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(3, clock: clock)
        let (a, b, c) = (all[0], all[1], all[2])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        #expect(await off(a), "nobody announced yet")
        _ = try await a.store.cloudOneRuleStep(); _ = try await b.store.cloudOneRuleStep()
        try await exchange(all, cursors, rows: ["I05"])
        #expect(await off(a), "C has not announced")
        #expect(await off(b))
        // C still holds phase 1's plain "1": it never counts.
        try await c.store.oneRulePhase2FixtureSetUnderstands("1")
        try await exchange(all, cursors, rows: ["I05"])
        #expect(await off(a))
        _ = try await c.store.cloudOneRuleStep()
        try await exchange(all, cursors, rows: ["I05"])
        // Review blocker 4: each Mac's next step makes its safety copy first; only then does it send.
        for f in all { _ = try await f.store.cloudOneRuleStep() }
        #expect(await sends(a))
        #expect(await sends(b))
        #expect(await sends(c))
        // C stops renewing (rolled back to an older build, or switched off): after 3 days and an hour it no longer counts.
        clock.advance(days: 3, hours: 1)
        await a.store.oneRulePhase2FixtureNewRun(); await b.store.oneRulePhase2FixtureNewRun()
        _ = try await a.store.cloudOneRuleStep(); _ = try await b.store.cloudOneRuleStep()
        try await exchange([a, b], cursors, rows: ["I05"])
        #expect(await off(a))
        #expect(await off(b))
        // C announces an OLDER format: still off.
        try await c.store.oneRulePhase2FixtureSetUnderstands(DeckMemoryStore.understandsValue(format: DeckMemoryStore.oneRuleFormat - 1, at: clock.now ?? 0))
        try await exchange(all, cursors, rows: ["I05"])
        #expect(await off(a))
        // C updated again: its new run renews with this format: on.
        await c.store.oneRulePhase2FixtureNewRun()
        _ = try await c.store.cloudOneRuleStep()
        try await exchange(all, cursors, rows: ["I05"])
        #expect(await sends(a))
        // A value from the future (a confused clock) never counts.
        #expect(!DeckMemoryStore.understandsFresh(DeckMemoryStore.understandsValue(format: DeckMemoryStore.oneRuleFormat, at: (clock.now ?? 0) + 2 * 3_600_000), now: clock.now ?? 0))
        #expect(!DeckMemoryStore.understandsFresh("1", now: clock.now ?? 0))
        #expect(!DeckMemoryStore.understandsFresh("v2:", now: clock.now ?? 0))
        // An unknown list, an empty one, or one without this Mac: off.
        await a.store.cloudOneRuleSetAccountMacs(nil)
        #expect(await off(a))
        await a.store.cloudOneRuleSetAccountMacs([])
        #expect(await off(a))
        await a.store.cloudOneRuleSetAccountMacs([b.deviceId, c.deviceId])
        #expect(await off(a))
        // A NEW Mac in the account that never announced (a new Mac on an old build): off.
        await a.store.cloudOneRuleSetAccountMacs([a.deviceId, b.deviceId, c.deviceId, UUID().uuidString.lowercased()])
        #expect(await off(a))
    }

    /// Phones and browsers never count as Macs; a revoked device, a replaced registration and a stale earlier entry
    /// never block; signed out = unknown.
    @Test func phonesAndBrowsersNeverCountAsMacs() throws {
        typealias F = BackendCloudContentsFixture
        let now: Int64 = 1_794_100_000_000
        let base = F.snapshot(now: now)
        func device(_ platform: CloudPlatform, status: CloudDeviceStatus = .active) -> CloudDevice {
            CloudDevice(deviceId: UUID().uuidString.lowercased(), label: "Other", platform: platform, appVersion: "1", status: status, secretsApproved: false,
                        lastSeenAt: now, signPublicJwk: F.key, wrapPublicJwk: F.key, registeredAt: now)
        }
        var replaced = device(.macos)
        replaced.supersededBy = F.mac
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: F.gate, devices: base.devices + [device(.ios), device(.android), device(.web), device(.macos, status: .revoked), replaced],
                                            trust: base.trust)
        #expect(Set(DeckMemoryStore.oneRuleAccountMacs(snapshot) ?? []) == Set([F.mac, F.pro, F.imac, F.mini]))
        #expect(DeckMemoryStore.oneRuleAccountMacs(CloudAccountSnapshot(phase: .signedOut, gate: F.gate, devices: base.devices)) == nil)
        #expect(DeckMemoryStore.oneRuleAccountMacs(CloudAccountSnapshot(phase: .signedIn, gate: F.gate, devices: [])) == nil)
    }

    /// The old moves switch cannot hold an explicit Everywhere delete. Its old-format marker still restores normally.
    @Test func anEverywhereRemovalTravelsBeforeTheMovesSwitchTurnsOn() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let before = try await allTexts(all)
        #expect(await off(a))
        _ = try await a.store.memoryRemove(path: "hoot/topics/t.md")
        let compatible = try await newChanges(a, "I01", cursors)
        #expect(removalOps(compatible).count == 1)
        #expect(markerTexts(compatible).allSatisfy { !$0.contains(CloudDeleteTravel.rule) })
        _ = try await b.apply(compatible, row: "I01")
        #expect(!exists(b, "hoot/topics/t.md"))
        try await switchOn(all, cursors, steps: 4)
        #expect(await sends(a))
        _ = try await a.store.memoryRemove(path: Self.note)
        try await exchange(all, cursors)
        #expect(!exists(a, Self.note) && !exists(b, Self.note))
        #expect(try await b.store.search(.init("retained decision", mode: .words)).hits.count == 0)
        #expect(try await b.store.memoryBin().map(\.path).contains(Self.note))
        try await b.store.memoryPutBack(path: Self.note)
        try await exchange(all, cursors)
        #expect(exists(a, Self.note) && exists(b, Self.note))
        #expect(try await a.store.search(.init("retained decision", mode: .words)).hits.count > 0)
        let after = try await allTexts(all)
        for t in before { #expect(after.contains(t)) }
    }

    /// Point 3: the archived-notes settling. Notes archived on A while sending was off left their old places live on B
    /// (and in the Cloud). Once sending is on: a move goes ONLY for an old place whose last Cloud text is the archived
    /// text; the old place B edited after the archive gets nothing, and that edit stays in use on both Macs.
    /// A fresh safety copy comes first. Every text survives.
    @Test func theArchivedNotesSettlingSendsMovesWithoutDelayAndNothingForAnEditedOldPlace() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let paths = (1...3).map { "hoot/notes/plan-\($0).md" }
        for (i, path) in paths.enumerated() {
            try a.write(path, "---\nid: n-plan-\(i + 1)\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Plan \(i + 1)\nWords of plan \(i + 1).\n")
        }
        _ = try await a.store.reindex()
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot"])
        try await exchange(all, cursors)
        #expect(paths.allSatisfy { exists(b, $0) })
        // Archived on A while sending is off (as on his Macs today): the archive copies travel, the old places do not go.
        for i in 1...3 { _ = try await a.store.archiveNote(id: "n-plan-\(i)", reason: "archived", replacedBy: nil) }
        try await a.store.cloudCaptureChangedFiles(paths: ["archive", "hoot"])
        try await exchange(all, cursors)
        _ = try await b.store.reindex()
        #expect(paths.allSatisfy { exists(b, $0) }, "phase 1: the old places stay on B")
        // B edits plan-2's old place AFTER the archive; the edit reaches A.
        try b.write(paths[1], "---\nid: n-plan-2\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Plan 2\nB's edit after the archive.\n")
        // As the app's folder watcher does for any edit made in the folder: B's index reads it (integration run 0220z:
        // without this the fixture's write was never indexed on B, so B's own search could not find it).
        _ = try await b.store.reindex()
        try await b.store.cloudCaptureChangedFiles(paths: [paths[1]])
        try await exchange(all, cursors)
        let before = try await allTexts(all)
        // Phase 2 on both Macs.
        try await switchOn(all, cursors)
        #expect(await sends(a))
        var moves: [DeckMemoryRemoval] = []
        for _ in 0..<12 {
            for f in all { _ = try await f.store.cloudOneRuleStep(limit: 8) }
            let fromA = try await newChanges(a, "I01", cursors), fromB = try await newChanges(b, "I01", cursors)
            moves += removalOps(fromA) + removalOps(fromB)
            if !fromA.isEmpty { _ = try await b.apply(fromA, row: "I01") }
            if !fromB.isEmpty { _ = try await a.apply(fromB, row: "I01") }
        }
        // Only moves (never a plain removal), only for the two unchanged old places.
        #expect(moves.allSatisfy { $0.movedTo != nil })
        #expect(!moves.isEmpty)
        #expect(!exists(a, paths[0]) && !exists(b, paths[0]) && !exists(a, paths[2]) && !exists(b, paths[2]))
        #expect(exists(a, "archive/" + paths[0]) && exists(b, "archive/" + paths[0]))
        // The edited old place: nothing sent, the edit in use on both.
        #expect(text(a, paths[1])?.hasSuffix("B's edit after the archive.\n") == true)
        #expect(text(b, paths[1])?.hasSuffix("B's edit after the archive.\n") == true)
        #expect(try await b.store.search(.init("after the archive", mode: .words)).hits.count > 0)
        // The moves are not in either Bin's list (the text lives on in the archived note); a note in use never is.
        let binA = try await a.store.memoryBin().map(\.path), binB = try await b.store.memoryBin().map(\.path)
        #expect(!binA.contains { paths.contains($0) } && !binB.contains { paths.contains($0) })
        // Its own fresh safety copy, and one honest line.
        let report = try await a.store.memoryOneRuleReport()
        #expect(report.phase2SafetyCopy != nil && report.phase2SafetyCopy != report.safetyCopy)
        #expect(report.phase2Finished)
        #expect(report.archivedLeft >= 1)
        #expect(report.phase2Line?.contains("Sent nothing for") == true)
        #expect(report.line.hasSuffix("Nothing was removed or moved on your other devices."))
        let after = try await allTexts(all)
        for t in before { #expect(after.contains(t)) }
    }

    /// Every proven move can settle in the same clock tick.
    @Test func theSettlingSendsEveryMoveWithoutWaitingBetweenBatches() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(1, clock: clock)
        let a = all[0]
        let cursors = Cursors()
        defer { Task { await a.close() } }
        let paths = (1...2).map { "hoot/notes/old-\($0).md" }
        for (i, path) in paths.enumerated() {
            try a.write(path, "---\nid: n-old-\(i + 1)\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Old \(i + 1)\nOld words \(i + 1).\n")
        }
        _ = try await a.store.reindex()
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot"])
        _ = try await newChanges(a, "I01", cursors)   // exported: the old places are in the Cloud (heads of A's resources)
        await a.store.cloudSetOneRuleSending(false)
        for i in 1...2 { _ = try await a.store.archiveNote(id: "n-old-\(i)", reason: "archived", replacedBy: nil) }
        try await a.store.cloudCaptureChangedFiles(paths: ["archive", "hoot"])
        _ = try await newChanges(a, "I01", cursors)
        await a.store.cloudSetOneRuleSending(true)
        for _ in 0..<6 { _ = try await a.store.cloudOneRuleStep() }
        #expect(try await a.store.memoryOneRuleReport().movesSent == 2)
        #expect(paths.allSatisfy { !exists(a, $0) && exists(a, "archive/" + $0) })
    }

    /// An older moves format closes that gate. Compatible deletes still go, and marker-note settling preserves bytes.
    @Test func aRolledBackMacStopsMovesButCompatibleDeletesStillTravelAndMarkerSettlingKeepsTheText() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        try await switchOn(all, cursors)
        #expect(await sends(a))
        let before = try await allTexts(all)
        // A removal travels; then B goes back to the phase-1 build, which writes "1" for itself.
        _ = try await a.store.memoryRemove(path: Self.note)
        let removal = try await newChanges(a, "I01", cursors)
        try await b.store.oneRulePhase2FixtureSetUnderstands("1")
        try await exchange(all, cursors, rows: ["I05"])
        #expect(await off(a), "the rolled-back Mac switched sending off")
        _ = try await a.store.memoryRemove(path: "hoot/topics/t.md")
        let compatible = try await newChanges(a, "I01", cursors)
        #expect(removalOps(compatible).count == 1)
        #expect(markerTexts(compatible).allSatisfy { !$0.contains(CloudDeleteTravel.rule) })
        _ = try await b.apply(compatible, row: "I01")
        #expect(!exists(b, "hoot/topics/t.md"))
        // The build before phase 1 placed the removal it received as the note's text.
        _ = try await b.apply(removal, row: "I01")
        // The marker's exact bytes, as the older build wrote them into the note's file.
        let marker = try #require(removal.compactMap { op -> String? in
            guard let part = try? JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload)),
                  let data = Data(base64Encoded: part.data), DeckMemoryRemoval.parse(data) != nil else { return nil }
            return String(data: data, encoding: .utf8)
        }.first)
        try b.write(Self.note, marker)
        _ = try await b.store.reindex()
        // B updated again: its next run settles the marker and renews its setting.
        await b.store.oneRulePhase2FixtureNewRun()
        for _ in 0..<6 { _ = try await b.store.cloudOneRuleStep() }
        #expect(!exists(b, Self.note), "the marker note is gone from B's memory")
        #expect(try await b.store.memoryBin().map(\.path).contains(Self.note), "its earlier text is in B's Bin")
        try await exchange(all, cursors, rows: ["I05"])
        #expect(await sends(a))
        let after = try await allTexts(all)
        for t in before { #expect(after.contains(t)) }
    }

    // MARK: Review fixes (14 Nov, phase 2 review: MERGE AFTER FIXES)

    /// An AI can remove a series of items at one clock time. A receiver applies the entire burst into its Bin.
    @Test func manySmallAIDeletesAreSentAndABurstArrivingAppliesImmediately() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let paths = (1...12).map { "hoot/notes/small-\($0).md" }
        try await shared(paths, on: a, all, cursors)
        try await switchOn(all, cursors, steps: 4)
        var ops: [CloudOperation] = []
        for path in paths {
            _ = try await a.store.memoryRemove(path: path, fromAI: true)
            let sent = try await newChanges(a, "I01", cursors)
            #expect(removalOps(sent).count == 1)
            ops += sent
        }
        #expect(removalOps(ops).count == paths.count)
        #expect(paths.allSatisfy { !exists(a, $0) && exists(b, $0) })
        _ = try await b.apply(ops, row: "I01")
        #expect(paths.allSatisfy { !exists(b, $0) })
        #expect(Set(try await b.store.memoryBin().map(\.path)).isSuperset(of: paths))
        #expect(try await b.store.notHere().isEmpty)
        #expect(try await b.store.oneRulePhase2FixtureHasHeldTable() == false)
    }

    /// The person can put a whole received burst back from the Bin; both Macs recover their files.
    @Test func anArrivingBurstGoesToTheBinAndManualPutBackAllRestoresBothMacs() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let paths = (1...2).map { "hoot/notes/keep-\($0).md" }
        try await shared(paths, on: a, all, cursors)
        try await switchOn(all, cursors, steps: 4)
        for path in paths { _ = try await a.store.memoryRemove(path: path) }
        let ops = try await newChanges(a, "I01", cursors)
        #expect(removalOps(ops).count == paths.count)
        _ = try await b.apply(ops, row: "I01")
        #expect(paths.allSatisfy { !exists(b, $0) })
        #expect(Set(try await b.store.memoryBin().map(\.path)).isSuperset(of: paths))
        let back = try await b.store.memoryPutBackAll(since: 0)
        #expect(Set(back.map(\.path)) == Set(paths))
        try await exchange(all, cursors)
        #expect(paths.allSatisfy { exists(a, $0) && exists(b, $0) })
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await b.store.memoryBin().isEmpty)
    }

    /// Compatible deletions sent while moves are off still lose to edits with independent ancestry.
    @Test func anEverywhereDeleteSentWhileMovesAreOffStillLosesToAnOfflineEdit() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let (gone, edited) = ("hoot/notes/gone.md", "hoot/notes/edited.md")
        try await shared([gone, edited], on: a, all, cursors)
        try await switchOn(all, cursors, steps: 4)
        await a.store.cloudOneRuleSetAccountMacs(nil)
        #expect(await off(a))
        _ = try await a.store.memoryRemove(path: gone)
        _ = try await a.store.memoryRemove(path: edited)
        let deletes = try await newChanges(a, "I01", cursors)
        #expect(removalOps(deletes).count == 2)
        #expect(markerTexts(deletes).allSatisfy { !$0.contains(CloudDeleteTravel.rule) })
        let newText = note("edited", "B's edit while A's moves switch was off.")
        try b.write(edited, newText)
        try await b.store.cloudCaptureChangedFiles(paths: [edited])
        let edits = try await newChanges(b, "I01", cursors)
        _ = try await a.apply(edits, row: "I01")
        _ = try await b.apply(deletes, row: "I01")
        #expect(!exists(a, gone) && !exists(b, gone))
        #expect(text(a, edited) == newText && text(b, edited) == newText)
        #expect(!(try await a.store.memoryBin().map(\.path).contains(edited)))
        #expect(!(try await b.store.memoryBin().map(\.path).contains(edited)))
        await a.store.cloudOneRuleSetAccountMacs(all.map(\.deviceId))
        for _ in 0..<2 { _ = try await a.store.cloudOneRuleStep() }
        #expect(removalOps(try await newChanges(a, "I01", cursors)).isEmpty, "the compatible delete was already sent")
    }

    /// Blocker 3: an edit made BEFORE a removal on the other Mac (offline) wins on both Macs, whichever Mac takes the
    /// other's change first, and also when the moves switch is off. Decided by revision ancestry, never the clock.
    @Test func anEarlierOfflineEditWinsOverARemovalOnBothMacsInBothOrdersAlsoWithTheMovesSwitchOff() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let (x, y, z) = ("hoot/notes/x.md", "hoot/notes/y.md", "hoot/notes/z.md")
        try await shared([x, y, z], on: a, all, cursors)
        try await switchOn(all, cursors, steps: 4)
        func offlineEdit(_ path: String) async throws -> (String, [CloudOperation]) {
            let t = note(String(path.dropFirst("hoot/notes/".count).dropLast(3)), "B's offline edit of " + path + ".")
            try b.write(path, t)
            try await b.store.cloudCaptureChangedFiles(paths: [path])
            return (t, try await newChanges(b, "I01", cursors))
        }
        // x: B edits at 10:50, A removes at 11:00. A takes B's edit first, then B takes A's removal.
        let (tx, editX) = try await offlineEdit(x)
        clock.advance(days: 0, minutes: 10)
        _ = try await a.store.memoryRemove(path: x)
        let removeX = try await newChanges(a, "I01", cursors)
        #expect(removalOps(removeX).count == 1)
        _ = try await a.apply(editX, row: "I01"); _ = try await b.apply(removeX, row: "I01")
        #expect(text(a, x) == tx && text(b, x) == tx)
        // y: the same, the other way round (B takes A's removal first).
        clock.advance(days: 0, minutes: 1)
        let (ty, editY) = try await offlineEdit(y)
        clock.advance(days: 0, minutes: 10)
        _ = try await a.store.memoryRemove(path: y)
        let removeY = try await newChanges(a, "I01", cursors)
        #expect(removalOps(removeY).count == 1)
        _ = try await b.apply(removeY, row: "I01"); _ = try await a.apply(editY, row: "I01")
        #expect(text(a, y) == ty && text(b, y) == ty)
        // z: A removes with moves switched off; B edits offline; the compatible removal still cannot erase the edit.
        clock.advance(days: 0, minutes: 1)
        await a.store.cloudOneRuleSetAccountMacs(nil)
        _ = try await a.store.memoryRemove(path: z)
        let (tz, editZ) = try await offlineEdit(z)
        await a.store.cloudOneRuleSetAccountMacs(all.map(\.deviceId))
        clock.advance(days: 0, minutes: 10)
        for _ in 0..<2 { _ = try await a.store.cloudOneRuleStep() }
        let removeZ = try await newChanges(a, "I01", cursors)
        #expect(removalOps(removeZ).count == 1, "the compatible removal was sent without waiting")
        _ = try await b.apply(removeZ, row: "I01"); _ = try await a.apply(editZ, row: "I01")
        #expect(text(a, z) == tz && text(b, z) == tz)
        for path in [x, y, z] {
            #expect(!(try await a.store.memoryBin().map(\.path).contains(path)))
            #expect(!(try await b.store.memoryBin().map(\.path).contains(path)))
        }
    }

    /// A failed safety copy keeps files in use and sends nothing; clearing the scratch obstruction permits retry.
    @Test func aFailedSafetyCopyKeepsTheFileAndRetryStillKeepsEveryText() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let blocked = try #require(await a.store.cloudSafetyRoot())
        let saved = blocked.deletingLastPathComponent().appendingPathComponent("safety-kept-for-test")
        if FileManager.default.fileExists(atPath: blocked.path) { try FileManager.default.moveItem(at: blocked, to: saved) }
        try Data("not a folder".utf8).write(to: blocked)
        try await switchOn(all, cursors, steps: 2)
        #expect(!(await a.store.cloudSafetyCopyReady()))
        #expect(await off(a))
        let original = try #require(text(a, Self.note))
        await #expect(throws: CloudFailure.self) { _ = try await a.store.memoryRemove(path: Self.note) }
        #expect(text(a, Self.note) == original && text(b, Self.note) == original)
        #expect(removalOps(try await newChanges(a, "I01", cursors)).isEmpty)
        try FileManager.default.removeItem(at: blocked)
        if FileManager.default.fileExists(atPath: saved.path) { try FileManager.default.moveItem(at: saved, to: blocked) }
        clock.advance(days: 0, hours: 1, minutes: 1)
        for _ in 0..<5 { _ = try await a.store.cloudOneRuleStep() }
        #expect(await a.store.cloudSafetyCopyReady())
        _ = try await a.store.memoryRemove(path: Self.note)
        let ops = try await newChanges(a, "I01", cursors)
        #expect(removalOps(ops).count == 1)
        _ = try await b.apply(ops, row: "I01")
        #expect(!exists(a, Self.note) && !exists(b, Self.note))
        #expect(try await a.store.oneRuleFixtureKeptTexts().contains(original))
        #expect(try await b.store.oneRuleFixtureKeptTexts().contains(original))
    }

    // MARK: Review round 2 (one look at 761c1c0b0)

    /// A script writing marker-shaped text cannot forge a delete. Its bytes are kept locally, and other Macs keep theirs.
    @Test func forgedMarkerTextIsNeverSentAsAnEditOrATravellingRemoval() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let paths = (1...6).map { "hoot/notes/forged-\($0).md" }
        try await shared(paths, on: a, all, cursors)
        try await switchOn(all, cursors, steps: 4)
        var forgedTexts = Set<String>()
        for (i, path) in paths.enumerated() {
            let marker = DeckMemoryRemoval(at: clock.now ?? 0, by: a.deviceId, movedTo: nil).text(id: "n-forged-\(i)", name: "Forged")
            forgedTexts.insert(marker)
            try a.write(path, marker)
        }
        _ = try await a.store.reindex()
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot"])
        #expect(removalOps(try await newChanges(a, "I01", cursors)).isEmpty)
        for _ in 0..<4 { _ = try await a.store.cloudOneRuleStep() }
        let ops = try await newChanges(a, "I01", cursors)
        #expect(removalOps(ops).isEmpty)
        #expect(markerTexts(ops).isEmpty)
        _ = try await b.apply(ops, row: "I01")
        #expect(paths.allSatisfy { exists(b, $0) })
        #expect(paths.allSatisfy { !exists(a, $0) })
        #expect(Set(try await a.store.notHere().compactMap(\.item.place)).isSuperset(of: paths))
        let kept = Set(try await a.store.oneRuleFixtureKeptTexts())
        #expect(forgedTexts.isSubset(of: kept))
        #expect(try await b.store.memoryBin().isEmpty)
    }

    /// Missing files remain marked until a direct Bring back action, which places the Cloud's newest bytes.
    @Test func bringBackPutsMarkedMissingNotesBackFromCloudAndSendsNoRemoval() async throws {
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        let all = try await macs(2, clock: clock)
        let (a, b) = (all[0], all[1])
        let cursors = Cursors()
        defer { Task { for f in all { await f.close() } } }
        let paths = (1...4).map { "hoot/notes/lost-\($0).md" }
        try await shared(paths, on: a, all, cursors)
        try await switchOn(all, cursors, steps: 4)
        let texts = paths.map { text(a, $0) }
        for path in paths { try FileManager.default.removeItem(at: a.root.appendingPathComponent(path)) }
        try await a.store.oneRuleFixtureResolveGoneByHand(paths)
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot"])
        let marked = try await a.store.notHere()
        #expect(marked.count == paths.count)
        #expect(marked.allSatisfy { $0.mark == .notOnThisMac })
        let broughtBack = try await a.store.bringBack(marked.map(\.item), to: .thisMac)
        #expect(broughtBack.count == paths.count)
        #expect(paths.map { text(a, $0) } == texts)
        #expect(try await a.store.notHere().isEmpty)
        let ops = try await newChanges(a, "I01", cursors)
        #expect(removalOps(ops).isEmpty)
        _ = try await b.apply(ops, row: "I01")
        #expect(paths.allSatisfy { exists(b, $0) })
    }
}

extension DeckMemoryStore {
    func oneRulePhase2FixtureHasHeldTable() throws -> Bool {
        try db.first("SELECT 1 FROM cloud.sqlite_master WHERE type='table' AND name='cloud_memory_held_removals'") != nil
    }
    /// What another build wrote for this Mac's "understands" key (phase 1's "1", an older format).
    func oneRulePhase2FixtureSetUnderstands(_ value: String) throws {
        guard let id = cloudDeviceId else { return }
        try setSetting(value, key: Self.understandsPrefix + id, owner: nil)
        post(.settings, nil, Self.understandsPrefix + id)
    }
    /// A relaunch: the next step renews the setting and looks for marker notes again.
    func oneRulePhase2FixtureNewRun() {
        cloudAnnouncedThisRun = false
        cloudStubsCheckedThisRun = false
    }
}
