import Foundation
import Darwin
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-8 (13 Nov): after the MacBook placed 37,939 memory rows that arrived from the Mac mini and its search index
/// caught up on them, the app's memory footprint stood at 19 GB (about half a megabyte per placed row) and never came
/// back. This places and indexes arrived rows of the real shape through the same code (waiting rows, the release pass,
/// the diary and note index, the bundled meaning model) and measures the process's own footprint as the count grows.
@Suite("Deck Memory — placing and indexing arrived rows uses flat memory", .serialized)
struct DeckMemoryCatchUpFootprintTests {
    static let otherStore = "bbe61469-0fb5-441c-bdac-2aa9258682c2"

    /// The process's footprint as Activity Monitor and `top` count it (phys_footprint), in bytes.
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
    /// The bundled model as the app ships it (macos/models/deck-memory-embedding).
    static func bundledModel() -> DeckMemoryCoreMLEmbedder? {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { folder.deleteLastPathComponent() }
        return DeckMemoryCoreMLEmbedder(folder: folder.appendingPathComponent("models/deck-memory-embedding", isDirectory: true))
    }

    private func op(row: String, key: String, body: Data) throws -> CloudOperation {
        let version = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: Self.otherStore, inventoryRow: row, key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        return CloudOperation(v: 1, opId: revision, originDevice: UUID().uuidString.lowercased(), domain: CloudBrainMemoryFormat.domain(row),
                              entityId: BackendCloudBrainMemoryHash.uuid(Self.otherStore + "\n" + key + "\n0"), revision: revision, parents: [], kind: .put,
                              source: .init(sourceId: "memory/" + row, recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                              payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
    }
    /// Words that differ row to row, so every text is its own and its token count varies (as real messages do).
    static let words = ["release", "memory", "index", "project", "session", "build", "check", "note", "diary", "search", "model",
                        "decided", "because", "the", "a", "fixed", "after", "before", "Mac", "mini", "MacBook", "cloud", "rows", "placed"]
    static func text(_ seed: Int, bytes: Int) -> String {
        var out = "", n = UInt64(truncatingIfNeeded: seed) &* 2_654_435_761
        while out.utf8.count < bytes {
            n = n &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out += Self.words[Int((n >> 33) % UInt64(Self.words.count))] + (n % 11 == 0 ? ".\n\n" : " ")
        }
        return out
    }
    /// A diary message of the joining Mac's shape: a few hundred bytes to a few KB, the person's or the AI's words.
    private func diary(project: String, id: Int) throws -> CloudOperation {
        let t = try DeckMemoryCloudSchema.table("diary")
        let size = 300 + (id * 7_919) % 3_700
        var values = [DeckMemorySQL](repeating: .null, count: t.columns.count)
        func set(_ column: String, _ value: DeckMemorySQL) { values[t.columns.firstIndex(of: column)!] = value }
        set("id", .int(Int64(id))); set("owner", .text("project:" + project)); set("project", .text(project))
        set("role", .text(id % 2 == 0 ? "user" : "assistant")); set("text", .text("\(project) message \(id): " + Self.text(id, bytes: size)))
        set("external_id", .text("\(project)-ext-\(id)")); set("at", .real(1_000_000 + Double(id))); set("saved", .real(1_000_000 + Double(id))); set("meta", .text("{}"))
        return try op(row: "I02", key: try DeckMemoryCloudSchema.key(t, values), body: try DeckMemoryCloudSchema.encodeRow(t, values))
    }
    /// A note file of several KB in the project's notes folder.
    private func note(project: String, id: Int) throws -> CloudOperation {
        let text = "---\nid: n-\(project)-\(id)\ndate: 2026-11-13T10:00:00Z\nseat: project:\(project)\ntype: note\n---\n# Note \(id) of \(project)\n"
            + Self.text(id &+ 99_991, bytes: 4_000 + (id * 104_729) % 4_000)
        return try op(row: "I01", key: "file/projects/\(project)/notes/n-\(id).md", body: Data(text.utf8))
    }

    /// Arrives first (its project not known here yet, so every row waits), then the project becomes known and ONE
    /// release places it all; then the index makes every vector.
    private func catchUp(_ b: CloudBrainMemoryFixture, _ known: KnownProjects, project: String, rows: Int) async throws -> (placed: Int, notes: Int) {
        var pending: [CloudOperation] = [], notes = 0
        var diaryOps: [CloudOperation] = [], noteOps: [CloudOperation] = []
        for index in 0..<rows {
            // About one row in eleven is a note file, as on the real pair (3,500 notes beside 39,900 diary rows).
            if index % 11 == 5 { noteOps.append(try note(project: project, id: index)); notes += 1 }
            else { diaryOps.append(try diary(project: project, id: index)) }
        }
        for (ops, row) in [(diaryOps, "I02"), (noteOps, "I01")] {
            for operation in ops {
                pending.append(operation)
                if pending.count == 500 { _ = try await b.apply(pending, row: row); pending = [] }
            }
            if !pending.isEmpty { _ = try await b.apply(pending, row: row); pending = [] }
        }
        let arrived = Self.footprint()
        known.add(project)
        let result = try await b.store.cloudReleaseWaitingProjects()
        let released = Self.footprint()
        await b.store.finishEmbedding()
        print("MAC-NEXT-8 \(project) \(rows) rows: arrived \(arrived / 1_048_576) MB, released \(released / 1_048_576) MB, indexed \(Self.footprint() / 1_048_576) MB")
        return (result.placed, notes)
    }

    /// The model sees five input shapes whatever the texts are (a program per length is what grew on the Neural Engine).
    @Test func theMeaningModelSeesAtMostFiveInputLengths() {
        #expect(Set((1...2_000).map(DeckMemoryCoreMLEmbedder.paddedLength)) == Set(DeckMemoryCoreMLEmbedder.lengths))
    }

    @Test func placingAndIndexingThousandsOfArrivedRowsKeepsTheFootprintFlat() async throws {
        guard let model = Self.bundledModel() else { Issue.record("The bundled meaning model is not in this checkout"); return }
        let b = try CloudBrainMemoryFixture(now: { Date() }, embedder: model)
        try await b.activate("I01"); try await b.activate("I02"); try await b.activate("I05")
        let known = KnownProjects()
        _ = try await b.store.cloudUseLeanProjectRule(then: { incoming, _ in known.has(incoming) ? incoming : nil })

        // 1,000 rows first: loads the model and warms every cache that is meant to stay (its size does not grow with rows).
        let warm = try await catchUp(b, known, project: "p-warm", rows: 1_000)
        #expect(warm.placed == 1_000)
        var notes = warm.notes
        let base = Self.footprint()
        var marks: [(rows: Int, bytes: Int64)] = []
        var total = 0
        for (round, rows) in [1_000, 1_000, 2_000].enumerated() {
            let done = try await catchUp(b, known, project: "p-\(round)", rows: rows)
            #expect(done.placed == rows, "Every arrived row is placed")
            total += rows; notes += done.notes
            marks.append((total, Self.footprint() - base))
        }
        let line = marks.map { "\($0.rows) rows: +\($0.bytes / 1_048_576) MB" }.joined(separator: ", ")
        print("MAC-NEXT-8 footprint after warm-up: " + line)
        // Flat: 4,000 more rows (placed AND given vectors) may not add more than a small fixed amount, and the last
        // 2,000 may not add more than the first 1,000 did plus a little (no growth per row).
        let growth = marks.last!.bytes
        #expect(growth < 48 * 1_048_576, "Footprint grew \(growth / 1_048_576) MB over 4,000 placed and indexed rows (\(line))")
        let perThousand = Double(growth) / 4.0 / 1_048_576
        #expect(perThousand < 12, "Growth per 1,000 rows: \(perThousand) MB (\(line))")

        // The index ends with every row searchable exactly once: one search row per diary row and note, every one of
        // them with its vectors, nothing left queued, no row given vectors twice.
        let check = try await b.store.cloudFixtureIndexCheck()
        #expect(check.queued == 0, "Nothing is left waiting for a vector")
        #expect(check.duplicateSearchRows == 0, "No row is in the search index twice")
        #expect(check.withoutVector == 0, "Every indexed row has its vectors")
        #expect(check.diary == 5_000 - notes, "Every arrived message is in the index once: \(check.diary)")
        #expect(check.notes == notes, "Every arrived note is in the index once: \(check.notes) of \(notes)")
        await b.close()
    }
}

private final class KnownProjects: @unchecked Sendable {
    private let lock = NSLock(); private var ids = Set<String>()
    func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    func has(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}

extension DeckMemoryStore {
    struct CloudFixtureIndexCheck { var queued = 0, duplicateSearchRows = 0, withoutVector = 0, diary = 0, notes = 0 }
    func cloudFixtureIndexCheck() throws -> CloudFixtureIndexCheck {
        func count(_ sql: String) throws -> Int { Int(try db.first(sql)?.int(0) ?? 0) }
        var check = CloudFixtureIndexCheck()
        check.queued = try count("SELECT COUNT(*) FROM embed_queue")
        check.duplicateSearchRows = try count("SELECT COUNT(*) FROM (SELECT kind,ref FROM search GROUP BY kind,ref HAVING COUNT(*) > 1)")
        check.withoutVector = try count("SELECT COUNT(*) FROM search_map m JOIN search s ON s.rowid=m.row WHERE (length(s.title)>0 OR length(s.body)>0) AND NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.kind=m.kind AND e.ref=m.ref)")
        check.diary = try count("SELECT COUNT(*) FROM search WHERE kind='diary' AND project LIKE 'p-%'")
        check.notes = try count("SELECT COUNT(*) FROM search WHERE kind='note' AND project LIKE 'p-%'")
        return check
    }
}
