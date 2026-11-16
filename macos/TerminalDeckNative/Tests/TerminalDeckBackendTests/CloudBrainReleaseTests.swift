import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Brain-merge lane (13 Nov, read-only check 2 of the two real Macs):
/// Y1 the joining MacBook placed 8,000 of 47,334 waiting rows and stopped: one row that threw rolled back its whole
///    batch, the callers' `try?` hid it, and every later pass met the same row first and placed nothing.
/// Y2 120 project and agent changes from the account's own Mac were held ("listed, not applied").
/// Y3 right after the merge the MacBook sent arrived memory back as its own (the echo the Mac mini then refused).
@Suite("Cloud brain — the release runs to the end, full access applies, nothing arrived is sent back", .serialized)
struct CloudBrainReleaseTests {
    /// The Mac mini: one other store for every arriving row, as on the real pair.
    static let otherStore = "bbe61469-0fb5-441c-bdac-2aa9258682c2"

    private func op(row: String, key: String, body: Data, store: String = Self.otherStore) throws -> (CloudOperation, String) {
        let version = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: store, inventoryRow: row, key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        let operation = CloudOperation(v: 1, opId: revision, originDevice: UUID().uuidString.lowercased(), domain: CloudBrainMemoryFormat.domain(row),
                                       entityId: BackendCloudBrainMemoryHash.uuid(store + "\n" + key + "\n0"), revision: revision, parents: [], kind: .put,
                                       source: .init(sourceId: "memory/" + row, recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                                       payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
        return (operation, hash)
    }
    /// One shared setting of a project, as the Mac mini's memory holds thousands of them per project.
    /// Integrator (MAC-NEXT-6): only allow-listed settings travel; any other key is this Mac's own and is never held
    /// for a project, so the rows use the shared "card.limit" key, one per seat of the project (owner role:<project>/rN).
    private func setting(project: String, index: Int) throws -> (CloudOperation, String) {
        try setting(owner: "role:" + project + "/r\(index)", index: index)
    }
    private func setting(owner: String, index: Int) throws -> (CloudOperation, String) {
        let t = try DeckMemoryCloudSchema.table("settings")
        let values: [DeckMemorySQL] = [.text(owner), .text("card.limit"), .text("value \(index)"), .real(1000.5)]
        return try op(row: "I05", key: try DeckMemoryCloudSchema.key(t, values), body: try DeckMemoryCloudSchema.encodeRow(t, values))
    }
    private func file(_ path: String, _ text: String, store: String = Self.otherStore) throws -> (CloudOperation, String) {
        try op(row: "I01", key: "file/" + path, body: Data(text.utf8), store: store)
    }
    private func localChanges(_ f: CloudBrainMemoryFixture, _ row: String) async throws -> [CloudOperation] {
        let adapter = try f.adapter(row)
        var cursor: String?, all: [CloudOperation] = []
        while let change = try await adapter.localChange(after: cursor) { all.append(change.operation); cursor = change.cursor }
        return all
    }

    // MARK: Y1

    /// MAC-NEXT-7 (5): the real 47,000-row shape scaled to a tenth (same projects, same proportions, same bad row in the
    /// middle of crm's rows) so the test takes seconds, plus one row-count-independent check: the work per row stays flat.
    @Test func aJoinWhoseProjectsArriveLaterEndsWithNothingReleasableWaitingAndABadRowParked() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05")
        let known = KnownProjects()
        _ = try await b.store.cloudUseLeanProjectRule(then: { incoming, _ in known.has(incoming) ? incoming : nil })
        // The Mac mini's shape at a tenth: four real projects and 138 rows of six test projects that exist nowhere.
        let plan: [(String, Int)] = [("terminal-deck", 3_200), ("imatch", 800), ("ipresent", 450), ("crm", 236),
                                     ("td-memory-test", 120), ("td-codex-probe", 4), ("users-imatch-td-memory-test", 3),
                                     ("probe-a", 5), ("probe-b", 3), ("probe-c", 3)]
        var all: [(project: String, index: Int, hash: String)] = [], pending: [CloudOperation] = []
        for (project, count) in plan {
            for index in 0..<count {
                let (operation, hash) = try setting(project: project, index: index)
                pending.append(operation); all.append((project, index, hash))
                if pending.count == 500 { _ = try await b.apply(pending, row: "I05"); pending = [] }
            }
        }
        if !pending.isEmpty { _ = try await b.apply(pending, row: "I05") }
        #expect(try await b.store.cloudWaitingCount() == 4_824, "Memory arrived before its projects: all of it waits")

        // One row in the MIDDLE of crm's rows cannot be placed (its kept copy is gone). It must not stop the rest.
        let bad = try #require(all.first { $0.project == "crm" && $0.index == 100 })
        let raw = try await b.store.cloudIncomingFolder().appendingPathComponent(Self.otherStore + "/" + bad.hash)
        try FileManager.default.removeItem(at: raw)

        // The four project records arrive. ONE release, with no page opened and no click, places everything.
        for project in ["terminal-deck", "imatch", "ipresent", "crm"] { known.add(project) }
        let visitsBefore = await b.store.cloudRevisits
        let result = try await b.store.cloudReleaseWaitingProjects()
        // Work per row stays flat (independent of how many rows wait): each row is visited a bounded number of times.
        let visits = await b.store.cloudRevisits - visitsBefore
        #expect(visits <= 2 * (result.placed + result.parked), "\(visits) visits for \(result.placed + result.parked) rows")
        #expect(result.placed == 4_685, "Every row of the four projects except the bad one: \(result.line)")
        #expect(result.parked == 1 && result.parkedNow == 1, "The bad row is set aside with its reason: \(result.line)")
        #expect(result.parkedReasons.values.reduce(0, +) == 1)
        #expect(result.waiting.isEmpty, "Nothing releasable is left waiting: \(result.line)")
        #expect(result.waitingForAbsentProjects == 138 && result.absentProjects == 6)
        #expect(try await b.store.cloudReleasableCount() == 0)
        #expect(try await b.store.cloudWaitingCount() == 138, "Only the rows of projects that exist nowhere still wait")

        // The rows before AND after the bad one are in real memory.
        #expect(try await b.store.value("card.limit", owner: .role(project: "crm", role: "r99")) == "value 99")
        #expect(try await b.store.value("card.limit", owner: .role(project: "crm", role: "r101")) == "value 101")
        #expect(try await b.store.value("card.limit", owner: .role(project: "crm", role: "r100")) == nil)
        #expect(try await b.store.value("card.limit", owner: .role(project: "terminal-deck", role: "r3199")) == "value 3199")
        #expect(try await b.store.value("card.limit", owner: .role(project: "imatch", role: "r0")) == "value 0")

        // The line names numbers and project ids only; projects that exist nowhere are not something to do.
        #expect(result.line.hasPrefix("cloud memory: released 4685; still waiting 0"))
        #expect(result.line.contains("138 kept for 6 projects that no signed-in device has"), "\(result.line)")
        #expect(!result.line.contains("users-imatch"), "Rows for projects that are nowhere are counted, not named")
        let readiness = try await b.store.cloudMemoryReadiness()
        #expect(!readiness.reasons.contains(DeckMemoryCloudLeanProjects.waitingLine(138)))
        #expect(readiness.counts.blocked == 1, "Only the set-aside row counts")

        // A second look finds nothing more to do and says nothing new.
        let again = try await b.store.cloudReleaseWaitingProjects()
        #expect(again.placed == 0 && again.parked == 0 && again.waiting.isEmpty)
        await b.close()
    }

    @Test func aNoteIdKnownHereUnderAnotherStoreIsTheSameNoteNotAClash() async throws {
        // Y1/Y3: the MacBook had re-captured arrived notes as its own; the next arrived note whose "supersedes" named
        // one of them threw idReused and rolled back a whole release batch.
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I05")
        let cell = CloudBrainMemoryCell(type: "text", value: "n-20261113-shared-note")
        let first = try await b.store.cloudResolveReference(.init(storeId: UUID().uuidString.lowercased(), table: "notes", id: cell))
        let second = try await b.store.cloudResolveReference(.init(storeId: Self.otherStore, table: "notes", id: cell))
        #expect(first == .text("n-20261113-shared-note"))
        #expect(second == first, "The same global note id is the same note")
        // Board ids stay per store (they are machine-local session ids): no change there.
        let board = CloudBrainMemoryCell(type: "text", value: "session-1")
        let one = try await b.store.cloudResolveReference(.init(storeId: UUID().uuidString.lowercased(), table: "board", id: board))
        let two = try await b.store.cloudResolveReference(.init(storeId: Self.otherStore, table: "board", id: board))
        #expect(one != two)
        await b.close()
    }

    // MARK: Y3

    @Test func applyingRemoteMemoryProducesZeroOutgoingRecordsUntilThisMacChangesIt() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05")
        // The Mac mini's note arrives: the file is placed and indexed here (which writes its label row on this Mac).
        let text = "---\nid: n-arrived-1\ndate: 2026-11-13T09:00:00Z\nseat: hoot\ntype: note\n---\n# Arrived\nDecided on the other Mac.\n"
        let (note, _) = try file("hoot/notes/arrived.md", text)
        let (shared, _) = try setting(owner: "hoot", index: 1)
        _ = try await b.apply([note], row: "I01")
        _ = try await b.apply([shared], row: "I05")
        #expect(FileManager.default.fileExists(atPath: b.root.appendingPathComponent("hoot/notes/arrived.md").path))

        // Everything that would send: a full reconcile of rows and files, then the outbox reads.
        try await b.store.cloudStartReconcile(full: true)
        var steps = 0
        while try await b.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
        let files = try await localChanges(b, "I01"), rows = try await localChanges(b, "I05")
        #expect(files.isEmpty, "The arrived file is not sent back: \(files.map(\.entityId))")
        #expect(rows.isEmpty, "Its label row and the arrived setting are not sent back as this Mac's own: \(rows.map(\.entityId))")

        // The person edits the arrived note on THIS Mac: now it travels (as the file, under its origin).
        try b.write("hoot/notes/arrived.md", text + "Edited on this Mac.\n")
        try await b.store.cloudStartReconcile(full: true)
        steps = 0
        while try await b.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
        let edited = try await localChanges(b, "I01")
        #expect(edited.count == 1, "A real change here is sent once")
        let part = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(try #require(edited.first).payload))
        #expect(part.storeId == Self.otherStore && part.key == "file/hoot/notes/arrived.md", "Same record, a descendant of the arrived version")
        let labels = try await localChanges(b, "I05")
        #expect(labels.isEmpty, "Labels of an arrived file are re-derived on every Mac; never sent from here")
        await b.close()
    }

    // MARK: MAC-NEXT-7

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var at = Date(timeIntervalSince1970: 1000.125)
        var now: Date { lock.withLock { at } }
        func advance(_ seconds: TimeInterval) { lock.withLock { at = at.addingTimeInterval(seconds) } }
    }

    /// Item 3: a row set aside is tried again when a project or agent record was applied, and within 10 minutes by
    /// itself; never only at the next app start.
    @Test func aSetAsideRowIsTriedAgainAfterARecordIsAppliedAndWithinTenMinutes() async throws {
        let clock = Clock()
        let b = try CloudBrainMemoryFixture(now: { clock.now })
        try await b.activate("I05")
        let known = KnownProjects()
        _ = try await b.store.cloudUseLeanProjectRule(then: { incoming, _ in known.has(incoming) ? incoming : nil })
        var rows: [(CloudOperation, String)] = []
        for index in 0..<3 { rows.append(try setting(project: "crm", index: index)) }
        _ = try await b.apply(rows.map(\.0), row: "I05")
        let folder = try await b.store.cloudIncomingFolder().appendingPathComponent(Self.otherStore)
        let kept1 = try Data(contentsOf: folder.appendingPathComponent(rows[1].1)), kept2 = try Data(contentsOf: folder.appendingPathComponent(rows[2].1))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(rows[1].1))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(rows[2].1))
        known.add("crm")
        let first = try await b.store.cloudReleaseWaitingProjects()
        #expect(first.placed == 1 && first.parkedNow == 2, "\(first.line)")
        #expect(first.line.contains("tried again within 10 minutes"))

        // The copy is back, but nothing new happened and 10 minutes have not passed: not tried yet.
        try kept1.write(to: folder.appendingPathComponent(rows[1].1))
        #expect(try await b.store.cloudReleaseWaitingProjects().parkedNow == 2)
        // 10 minutes later the next release tries every set-aside row again: one is placed, one is set aside again.
        clock.advance(601)
        let later = try await b.store.cloudReleaseWaitingProjects()
        #expect(later.placed == 1 && later.parkedNow == 1, "\(later.line)")
        #expect(try await b.store.value("card.limit", owner: .role(project: "crm", role: "r1")) == "value 1")

        // A project or agent record is applied: tried again at once, no clock needed.
        try kept2.write(to: folder.appendingPathComponent(rows[2].1))
        #expect(try await b.store.cloudReleaseWaitingProjects().parkedNow == 1)
        await b.store.cloudRetrySetAsideNow()
        let applied = try await b.store.cloudReleaseWaitingProjects()
        #expect(applied.placed == 1 && applied.parkedNow == 0, "\(applied.line)")
        #expect(try await b.store.cloudSetAsideRetryAt() == nil, "nothing set aside: no timer")
        await b.close()
    }

    /// Top item (MacBook, 13 Nov 14:56): rows for projects that no device has are kept quietly and never start a pass
    /// by themselves; the line names them truthfully.
    @Test func rowsKeptForAbsentProjectsNeverStartAPassByThemselves() async throws {
        let clock = Clock()
        let b = try CloudBrainMemoryFixture(now: { clock.now })
        try await b.activate("I05")
        _ = try await b.store.cloudUseLeanProjectRule(then: { _, _ in nil })
        _ = try await b.apply(try (0..<3).map { try setting(project: "td-memory-test", index: $0).0 }, row: "I05")
        let walks = await b.store.cloudReleaseWalks
        for _ in 0..<3 {
            let pass = try await b.store.cloudReleaseWaitingProjects()
            #expect(pass.placed == 0 && pass.waiting.isEmpty)
            #expect(pass.line.contains("3 kept for 1 project that no signed-in device has"), "\(pass.line)")
            clock.advance(601)
        }
        #expect(await b.store.cloudReleaseWalks == walks, "no pass walked rows that nothing can place")
        // Defect A (real check 3): kept rows are not "arriving": the pages can say "Up to date" / "All saved".
        let page = try await b.store.cloudPageRead(withTitles: false)
        #expect(page.arriving.values.reduce(0, +) == 0, "\(page.arriving)")
        await b.close()
    }

    /// Defect C (real check 3): a note placed from the Cloud is never rewritten here by the short-title helper (that
    /// rewrite went straight back as this Mac's edit, once each way), and placing it produces zero outgoing records.
    @Test func anArrivedNoteIsNeverRetitledHereAndNothingOfItGoesBack() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05")
        let text = "---\nid: n-arrived-lessons\ndate: 2026-11-11T18:00:00Z\nseat: hoot\ntype: note\n---\n# Local workbench lessons 2026-11-11 + session checkpoint\nWhat was learned.\n"
        let (note, _) = try file("hoot/notes/2026-11-11-local-workbench-lessons-session-checkpoint.md", text)
        _ = try await b.apply([note], row: "I01")
        try b.write("hoot/notes/own.md", "---\nid: n-own-here\ndate: 2026-11-13T09:00:00Z\nseat: hoot\ntype: note\n---\n# Written on this Mac\nMine.\n")
        _ = try await b.store.reindex()
        let arrived = await b.store.cloudArrivedNoteIDs(["n-arrived-lessons", "n-own-here"])
        #expect(arrived == ["n-arrived-lessons"])
        let asked = await DeckMemoryShortTitles.missing(b.store, skipping: []).map { DeckMemoryShortTitles.key($0) }
        #expect(!asked.contains("note:n-arrived-lessons"), "the arrived note is titled on the device that wrote it")
        #expect(asked.contains("note:n-own-here"))
        try await b.store.cloudStartReconcile(full: true)
        var steps = 0
        while try await b.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
        let sent = try await localChanges(b, "I01") + localChanges(b, "I05")
        let keys = try sent.map { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload)).key }
        #expect(!keys.contains { $0.contains("local-workbench-lessons") }, "\(keys)")
        await b.close()
    }

    /// Top item: a project whose RECORD arrived (no folder here), with a display name that differs from its id
    /// ("Deck Dev" for terminal-deck), is known to memory BEFORE the first release: its rows are placed by that release
    /// and never called absent. Before, the resolver's set filled only at the first capture pass.
    @Test func anArrivedProjectRecordWithoutAFolderReleasesItsMemoryAtTheFirstPass() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I05")
        _ = try await b.store.cloudUseLeanProjectRule(then: { _, _ in nil })
        _ = try await b.apply(try (0..<5).map { try setting(project: "terminal-deck", index: $0).0 }, row: "I05")
        let registry = BackendPROJRegistry(fileURL: b.base.appendingPathComponent("projects.registry.json"), changed: { _ in })
        try await registry.cloudLeanWrite(PROJProject(id: "terminal-deck", name: "Deck Dev"))
        let owner = BackendCloudLeanProjects(registry: registry)
        #expect(owner.memoryResolver()("terminal-deck", Self.otherStore) == nil, "not read yet")
        await owner.confirmProjects()
        #expect(owner.memoryResolver()("terminal-deck", Self.otherStore) == "terminal-deck")
        #expect(owner.memoryResolver()("Deck Dev", Self.otherStore) == nil, "matched by id, never by display name")
        _ = try await b.store.cloudUseLeanProjectRule(then: owner.memoryResolver())
        let pass = try await b.store.cloudReleaseWaitingProjects()
        #expect(try await b.store.cloudWaitingCount() == 0, "\(pass.line)")
        #expect(!pass.line.contains("kept for"))
        #expect(try await b.store.value("card.limit", owner: .role(project: "terminal-deck", role: "r4")) == "value 4")
        await b.close()
    }

    /// Item 4: a third Mac joining later. Items of Mac A (store A) reach B; items of A and B reach C. A first copy taken
    /// on B or C AFTER they received those items holds none of them, and an arrived item travels from C only once it
    /// was edited there.
    @Test func aThirdMacJoiningLaterNeverSendsReceivedItemsAsItsOwn() async throws {
        let storeB = UUID().uuidString.lowercased()
        let noteA = "---\nid: n-from-a\ndate: 2026-11-13T09:00:00Z\nseat: hoot\ntype: note\n---\n# From A\nDecided on A.\n"
        let noteB = "---\nid: n-from-b\ndate: 2026-11-13T09:30:00Z\nseat: hoot\ntype: note\n---\n# From B\nDecided on B.\n"
        let fromA = [try file("hoot/notes/from-a.md", noteA).0, try setting(owner: "hoot", index: 7).0]
        let fromB = [try file("hoot/notes/from-b.md", noteB, store: storeB).0]
        func keys(_ ops: [CloudOperation]) throws -> Set<String> {
            Set(try ops.map { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload)).key })
        }
        let received = try keys(fromA + fromB)
        for (name, arrivals) in [("B", fromA), ("C", fromA + fromB)] {
            let mac = try CloudBrainMemoryFixture()
            try await mac.activate("I01"); try await mac.activate("I05")
            for op in arrivals { _ = try await mac.apply([op], row: op.domain == CloudBrainMemoryFormat.domain("I01") ? "I01" : "I05") }
            // The first copy, taken now (a new cut), as a Mac that joins later takes it.
            let copy = try await mac.snapshot("I01").operations + mac.snapshot("I05").operations
            let copied = try keys(copy)
            #expect(copied.isDisjoint(with: received), "\(name)'s first copy holds received items: \(copied.intersection(received))")
            try await mac.store.cloudStartReconcile(full: true)
            var steps = 0
            while try await mac.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
            let sent = try await localChanges(mac, "I01") + localChanges(mac, "I05")
            #expect(try keys(sent).isDisjoint(with: received), "\(name) sends received items as its own")
            if name == "C" {
                try mac.write("hoot/notes/from-a.md", noteA + "Edited on C.\n")
                try await mac.store.cloudStartReconcile(full: true)
                steps = 0
                while try await mac.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
                let edited = try await localChanges(mac, "I01")
                #expect(try keys(edited) == ["file/hoot/notes/from-a.md"], "an item edited here travels")
            }
            await mac.close()
        }
    }

    private final class KnownProjects: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
        func has(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    }

    // MARK: 15 Nov — an archived project's memory from the other Mac

    /// One diary message of a project, as the Mac mini's 68 entries of the archived project (lead and seat owners).
    private func diary(owner: String, project: String, id: Int) throws -> CloudOperation {
        let t = try DeckMemoryCloudSchema.table("diary")
        var values = [DeckMemorySQL](repeating: .null, count: t.columns.count)
        func set(_ column: String, _ value: DeckMemorySQL) { values[t.columns.firstIndex(of: column)!] = value }
        set("id", .int(Int64(id))); set("owner", .text(owner)); set("project", .text(project))
        set("role", .text(id % 2 == 0 ? "user" : "assistant")); set("text", .text("message \(id)"))
        set("external_id", .text("\(project)-ext-\(id)")); set("at", .real(1_000_000 + Double(id))); set("saved", .real(1_000_000 + Double(id))); set("meta", .text("{}"))
        return try op(row: "I02", key: try DeckMemoryCloudSchema.key(t, values), body: try DeckMemoryCloudSchema.encodeRow(t, values)).0
    }

    /// One index entry (a notes label) of a project's file, from the other Mac, as the MacBook's two note entries.
    private func label(owner: String, path: String, date: Double, store: String = Self.otherStore) throws -> CloudOperation {
        let t = try DeckMemoryCloudSchema.table("notes")
        var values = [DeckMemorySQL](repeating: .null, count: t.columns.count)
        func set(_ column: String, _ value: DeckMemorySQL) { values[t.columns.firstIndex(of: column)!] = value }
        set("id", .text("n-" + UUID().uuidString.lowercased())); set("path", .text(path)); set("title", .text("Label title"))
        set("type", .text("decision")); set("owner", .text(owner)); set("date", .real(date)); set("source", .text("")); set("updated", .real(date))
        let body = try CloudWire.canonical(CloudBrainMemoryRow(table: "notes", columns: t.columns, cells: values.map(DeckMemoryCloudSchema.cell),
            references: ["path": .init(storeId: store, table: "file", id: .init(type: "text", value: path))]))
        return try op(row: "I05", key: try DeckMemoryCloudSchema.key(t, values), body: body, store: store).0
    }
    /// A file under `archive/` travels in its own inventory row (I06, `DeckMemoryCloudSchema.fileRow`), never in I01:
    /// sent in I01 the import refuses it as `.unsupportedFormat` (the first run of these tests did exactly that).
    private func archiveFile(_ path: String, _ text: String, store: String = Self.otherStore) throws -> (CloudOperation, String) {
        try op(row: "I06", key: "file/" + path, body: Data(text.utf8), store: store)
    }
    private static let archivedNote = "---\nid: n-kept\ndate: 2026-10-11T10:00:00Z\nseat: project:old-archived\ntype: note\n---\n# Kept\nOld.\n"

    /// The MacBook kept 80 rows (68 diary) "for 1 project that no signed-in device has": a project archived on both
    /// Macs, in no project list, whose files had arrived from the Mac mini under `archive/`. Its rows now go into memory
    /// under the same archived id, the count for it is zero, nothing is un-archived, a project in neither place still
    /// waits, and after the release the other Mac receives no new archive files from this one.
    @Test func anArchivedProjectsDiaryFromTheOtherMacIsPlacedAndNothingIsUnarchived() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I02"); try await b.activate("I05"); try await b.activate("I06")
        _ = try await b.store.cloudUseLeanProjectRule(then: { _, _ in nil })
        let archived = "old-archived", nowhere = "never-here"
        let owners = ["lead:" + archived, "role:" + archived + "/builder", "project:" + archived]
        _ = try await b.apply(try (0..<6).map { try diary(owner: owners[$0 % 3], project: archived, id: $0) }, row: "I02")
        _ = try await b.apply(try (0..<2).map { try diary(owner: "project:" + nowhere, project: nowhere, id: 100 + $0) }, row: "I02")
        let before = try await b.store.cloudReleaseWaitingProjects()
        #expect(before.placed == 0 && before.waitingForAbsentProjects == 8 && before.absentProjects == 2, "\(before.line)")

        // The archived project's file arrives from the other Mac under `archive/` (as the Mac mini's 16 did): this Mac
        // now holds that project in its archive, from that very Mac, and in no project list.
        _ = try await b.apply([try archiveFile("archive/projects/\(archived)/notes/kept.md", Self.archivedNote).0], row: "I06")
        let sentBefore = try await localChanges(b, "I06").filter { $0.source.recordId.hasPrefix("file/archive/") }.count
        let result = try await b.store.cloudReleaseWaitingProjects()
        #expect(result.placed == 6 && result.placedForArchived == 6 && result.archivedProjects == 1, "\(result.line)")
        #expect(result.waiting.isEmpty, "\(result.line)")
        #expect(result.waitingForAbsentProjects == 2 && result.absentProjects == 1, "Only the project in neither place waits: \(result.line)")
        #expect(result.line.contains("placed 6 for 1 archived project"), "\(result.line)")
        #expect(result.line.contains("2 kept for 1 project that no signed-in device has"), "\(result.line)")
        #expect(!result.line.contains(archived) && !result.line.contains(nowhere), "Counts only, never names: \(result.line)")
        #expect(try await b.store.cloudWaitingByProject().unknown[archived] == nil, "Nothing is kept for the archived project")

        // In memory, exactly under the archived project's own owners.
        #expect(try await b.store.diary(.init(project: archived, limit: 50)).count == 6)
        #expect(try await b.store.diary(.init(project: nowhere, limit: 50)).isEmpty)

        // A file of that project from the other Mac goes beside its archived files, never into a live project folder.
        _ = try await b.apply([try file("projects/\(archived)/notes/late.md", "late words").0], row: "I01")
        #expect(FileManager.default.fileExists(atPath: b.root.appendingPathComponent("archive/projects/\(archived)/notes/late.md").path))

        // Nothing is un-archived: no live project folder, no project in the lean list.
        #expect(!FileManager.default.fileExists(atPath: b.root.appendingPathComponent("projects/" + archived).path))
        #expect(!DeckMemoryCloudLeanProjects.known(memoryRoot: b.root).contains(archived))

        // The other Mac receives no new archive files from this one: what arrived is never sent back (a full reconcile
        // of files, then the outbox reads, as in the echo test above).
        try await b.store.cloudStartReconcile(full: true)
        var steps = 0
        while try await b.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
        let sentAfter = try await localChanges(b, "I06").filter { $0.source.recordId.hasPrefix("file/archive/") }.count
        #expect(sentBefore == 0 && sentAfter == 0, "\(sentBefore) / \(sentAfter) archive files sent")

        // A second look has nothing more to place.
        let again = try await b.store.cloudReleaseWaitingProjects()
        #expect(again.placed == 0 && again.waitingForAbsentProjects == 2, "\(again.line)")
        await b.close()
    }

    /// Review M1: ids are name slugs, unique on one Mac only. This Mac archived its OWN "website"; the other Mac has an
    /// unrelated live "website" whose project record has not arrived yet. Nothing of the other Mac's goes into this
    /// archive (no mixing, the archived file is untouched); it waits, and lands in the live project once the record is here.
    @Test func twoUnrelatedProjectsWithTheSameIdAreNeverMixedAndALiveOneOnItsWayWaits() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I02"); try await b.activate("I05")
        let known = KnownProjects()
        _ = try await b.store.cloudUseLeanProjectRule(then: { incoming, _ in known.has(incoming) ? incoming : nil })
        let id = "website", mine = "---\nid: n-mine\ndate: 2026-09-01T10:00:00Z\nseat: project:website\ntype: note\n---\n# Mine\nThis Mac's own.\n"
        try b.write("archive/projects/\(id)/notes/same.md", mine)
        _ = try await b.apply(try (0..<3).map { try diary(owner: "project:" + id, project: id, id: $0) }, row: "I02")
        _ = try await b.apply([try file("projects/\(id)/notes/same.md", "the other Mac's live text").0], row: "I01")
        let held = try await b.store.cloudReleaseWaitingProjects()
        #expect(held.placed == 0 && held.placedForArchived == 0, "\(held.line)")
        #expect(held.waitingForAbsentProjects == 4 && held.absentProjects == 1, "\(held.line)")
        #expect(try await b.store.diary(.init(project: id, limit: 50)).isEmpty, "Nothing went into this Mac's archived project")
        #expect(try String(contentsOf: b.root.appendingPathComponent("archive/projects/\(id)/notes/same.md"), encoding: .utf8) == mine)

        // The live project's record arrives: its memory goes into the LIVE project, never the archive.
        known.add(id)
        let landed = try await b.store.cloudReleaseWaitingProjects()
        #expect(landed.placed == 4 && landed.placedForArchived == 0 && landed.waitingForAbsentProjects == 0, "\(landed.line)")
        #expect(FileManager.default.fileExists(atPath: b.root.appendingPathComponent("projects/\(id)/notes/same.md").path))
        #expect(try String(contentsOf: b.root.appendingPathComponent("archive/projects/\(id)/notes/same.md"), encoding: .utf8) == mine)
        await b.close()
    }

    /// Review M2: an archived project's index entry that arrives BEFORE its file is kept (marked), not dropped, and is
    /// restored with its own labels when the file comes.
    @Test func anArchivedIndexEntryThatArrivesBeforeItsFileIsRestoredWhenTheFileComes() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05"); try await b.activate("I06")
        _ = try await b.store.cloudUseLeanProjectRule(then: { _, _ in nil })
        let archived = "old-archived", path = "archive/projects/old-archived/notes/late.md"
        _ = try await b.apply([try archiveFile("archive/projects/\(archived)/notes/kept.md", Self.archivedNote).0], row: "I06")
        let entry = try label(owner: "project:" + archived, path: path, date: 1_234.5)
        _ = try await b.apply([entry], row: "I05")
        #expect(try await b.store.cloudFixtureProjection(key: entry.source.recordId) == DeckMemoryStore.cloudLabelAwaitingArchivedFile)

        _ = try await b.apply([try archiveFile(path, "---\nid: n-late\ndate: 2026-10-11T10:00:00Z\nseat: project:old-archived\ntype: note\n---\n# Late\nArrived later.\n").0], row: "I06")
        let projection = try await b.store.cloudFixtureProjection(key: entry.source.recordId)
        #expect(projection != nil && projection != DeckMemoryStore.cloudLabelAwaitingArchivedFile && projection != "", "\(projection ?? "nil")")
        #expect(try await b.store.cloudFixtureNoteDate(path: path) == 1_234.5, "The entry's own date is restored")
        await b.close()
    }
}

/// Y2: with the device-trust setting at its default ("Automatically, with my account") project and agent changes from
/// the account's own trusted device are applied in full, including those held earlier; "Ask me for each new device"
/// keeps them held and listed. Nothing from the Cloud starts work.
@Suite("Cloud lean — full access with the account applies project and agent changes")
struct CloudLeanFullAccessTests {
    final class Access: @unchecked Sendable {
        private let lock = NSLock()
        private var full: Bool
        init(_ full: Bool) { self.full = full }
        func set(_ value: Bool) { lock.withLock { full = value } }
        var value: Bool { lock.withLock { full } }
    }
    struct AgentsSide: Sendable {
        let mac: CloudLeanFixtureMac
        let config: BackendTaskConfiguration
        let adapter: CloudBrainRecordAdapter
        let notices: CloudLeanFixture.Counter
    }
    static func agents(_ device: String, clock: CloudLeanFixture.Clock, access: Access, projects: [String]) async throws -> AgentsSide {
        let mac = try CloudLeanFixture.mac(device, clock: clock)
        let notices = CloudLeanFixture.Counter()
        let folder = mac.root.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = try BackendTaskConfiguration(persistence: try BackendTaskPersistence(directory: folder, ownership: .exclusive), changed: { notices.bump() })
        try await config.start()
        let owner = BackendCloudLeanAgents(config: config, historyFile: mac.root.appendingPathComponent("cloud").appendingPathComponent("a2-agent-names.json"),
            firstArrivalConfirmed: { false }, fullAccess: { access.value }, projects: { projects })
        return AgentsSide(mac: mac, config: config, adapter: try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins), notices: notices)
    }
    private func waiting(_ adapter: CloudBrainRecordAdapter) async throws -> [String] {
        try await adapter.listing().waiting.map { $0.record + "/" + $0.field }
    }
    private static func agent(_ id: String, _ name: String, _ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(([("id", .string(id)), ("name", .string(name)), ("provider", .string("claude"))] + pairs).map { NativeRPCValue.Field($0.0, $0.1) })
    }
    private static let wide: [(String, NativeRPCValue)] = [("permissionMode", .string("bypassPermissions")), ("seat", .string("reviewer")),
        ("projectId", .string("deck")), ("account", .string("login-on-mac-a"))]

    @Test func defaultTrustAppliesAnAgentInFullFromTheAccountsOwnMac() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock: clock, access: Access(true), projects: ["deck"])
        let b = try await Self.agents(CloudLeanFixture.deviceB, clock: clock, access: Access(true), projects: ["deck"])
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent("reviewer", "Reviewer", Self.wide))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        let noticesBefore = b.notices.count
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let arrived = try #require(try await b.config.agent("reviewer"))
        #expect(arrived["permissionMode"].string == "bypassPermissions", "Full access: applied with no click")
        #expect(arrived["seat"].string == "reviewer")
        #expect(arrived["projectId"].string == "deck")
        #expect(arrived["account"].string == nil, "Which login a Mac uses stays per Mac")
        let held = try await waiting(b.adapter)
        #expect(!held.contains { $0.hasPrefix("agent:reviewer/") }, "Nothing held: \(held)")
        #expect(b.notices.count == noticesBefore, "Nothing from the Cloud starts work: no change notice")
    }

    @Test func strictModeHoldsAndSwitchingToTheDefaultReleasesWhatWasHeld() async throws {
        let clock = CloudLeanFixture.Clock()
        let access = Access(false)
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock: clock, access: Access(true), projects: ["deck"])
        let b = try await Self.agents(CloudLeanFixture.deviceB, clock: clock, access: access, projects: ["deck"])
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent("builder", "Builder", [("permissionMode", .string("acceptEdits"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        // "Ask me for each new device": held and listed, exactly as before.
        #expect(try await b.config.agent("builder")?["permissionMode"].string == nil)
        #expect(try await waiting(b.adapter).contains("agent:builder/permissionMode"))
        // A later widening from A is held too.
        _ = try await a.config.saveAgent(Self.agent("builder", "Builder", [("permissionMode", .string("bypassPermissions"))]))
        try await CloudLeanFixture.deliver(try await CloudLeanFixture.sync(startedA.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        #expect(try await b.config.agent("builder")?["permissionMode"].string == nil)

        // The setting goes back to "Automatically, with my account": the held change applies by itself at the next
        // capture pass (the same happens at every launch), with no click.
        access.set(true)
        _ = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(try await b.config.agent("builder")?["permissionMode"].string == "bypassPermissions")
        #expect(!(try await waiting(b.adapter)).contains("agent:builder/permissionMode"))
        let echo = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(echo.isEmpty, "What was applied from the Cloud is not sent back")
    }

    @Test func aProjectLeadFromTheAccountsOwnMacIsAppliedWithFullAccessAndHeldInStrictMode() async throws {
        for full in [true, false] {
            let clock = CloudLeanFixture.Clock()
            let a = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock)
            let mac = try CloudLeanFixture.mac(CloudLeanFixture.deviceB, clock: clock)
            defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: mac.root) }
            let registry = BackendPROJRegistry(fileURL: mac.root.appendingPathComponent("projects.registry.json"), changed: { _ in })
            let owner = BackendCloudLeanProjects(registry: registry, fullAccess: { full })
            let adapter = try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins)
            _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", folders: ["/Users/person-a/Code/deck"], colour: "teal",
                lead: "agent:lead-a", leadName: "Lead A"))
            let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
            _ = try await CloudLeanFixture.start([adapter], on: mac)
            try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: adapter)
            let arrived = try await registry.projects().first { $0.id == "deck" }
            let held = try await adapter.listing().waiting.map { $0.record + "/" + $0.field }
            if full {
                #expect(arrived?.lead == "agent:lead-a" && arrived?.leadName == "Lead A")
                #expect(!held.contains("project:deck/lead"))
            } else {
                #expect(arrived?.lead == "")
                #expect(held.contains("project:deck/lead"))
            }
            #expect(arrived?.folders == [], "Folders stay per Mac in both modes")
        }
    }

}

extension DeckMemoryStore {
    /// Test-only: the kept projection of the newest version of one memory record.
    func cloudFixtureProjection(key: String) throws -> String? {
        try db.first("SELECT projection FROM cloud_memory_versions WHERE resource_key=? ORDER BY rowid DESC LIMIT 1", [.text(key)])?.string(0)
    }
    /// Test-only: the date of the note index entry at a path.
    func cloudFixtureNoteDate(path: String) throws -> Double? {
        guard let row = try db.first("SELECT date FROM notes WHERE path=?", [.text(path)]) else { return nil }
        if case .real(let value) = row.values[0] { return value }
        return nil
    }
}
