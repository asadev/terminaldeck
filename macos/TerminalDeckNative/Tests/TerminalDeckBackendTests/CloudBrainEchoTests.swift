import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-6 (13 Nov, the owner's Mac mini stuck at 404 of 407). The MacBook re-sent 250 of the Mac mini's notes under
/// its own store id; their `superseded_by` named a note id the Mac mini already held under its own store, and the
/// reference resolver refused with `idReused`, which stopped the whole feed. And on the joining MacBook every arrived
/// memory file walked every label row still waiting for its file (about 1,700), so its first packs took 20-35 s each.
@Suite("Cloud brain — an echoed note resolves to the same note; an arrived file reads only its own labels", .serialized)
struct CloudBrainEchoTests {
    @Test func aTextIdKnownUnderAnotherStoreIsTheSameNoteAndIntegerIdsStayApart() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I05")
        let mini = UUID().uuidString.lowercased(), book = UUID().uuidString.lowercased()
        let note = CloudBrainMemoryCell(type: "text", value: "n-20261013-shared")
        let first = try await b.store.cloudResolveReference(.init(storeId: mini, table: "notes", id: note))
        let echoed = try await b.store.cloudResolveReference(.init(storeId: book, table: "notes", id: note))
        #expect(first == echoed)
        let diaryMini = try await b.store.cloudResolveReference(.init(storeId: mini, table: "diary", id: .init(type: "integer", value: "1992")))
        let diaryBook = try await b.store.cloudResolveReference(.init(storeId: book, table: "diary", id: .init(type: "integer", value: "1992")))
        #expect(diaryMini != diaryBook, "a diary number is local to one Mac")
        await b.close()
    }

    private func part(store: String, row: String, key: String, body: Data) throws -> CloudOperation {
        let version = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: store, inventoryRow: row, key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        return CloudOperation(v: 1, opId: revision, originDevice: UUID().uuidString.lowercased(), domain: CloudBrainMemoryFormat.domain(row),
                              entityId: BackendCloudBrainMemoryHash.uuid(store + "\n" + key + "\n0"), revision: revision, parents: [], kind: .put,
                              source: .init(sourceId: "memory/" + row, recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                              payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
    }
    private func label(store: String, path: String) throws -> CloudOperation {
        let t = try DeckMemoryCloudSchema.table("notes")
        var values = [DeckMemorySQL](repeating: .null, count: t.columns.count)
        values[t.columns.firstIndex(of: "id")!] = .text("n-" + UUID().uuidString.lowercased())
        values[t.columns.firstIndex(of: "path")!] = .text(path)
        values[t.columns.firstIndex(of: "title")!] = .text("Note")
        for (column, value) in [("type", DeckMemorySQL.text("note")), ("owner", .text("hoot")), ("date", .real(1000.5)), ("source", .text("")), ("updated", .real(1000.5))] {
            if let i = t.columns.firstIndex(of: column) { values[i] = value }
        }
        let body = try CloudWire.canonical(CloudBrainMemoryRow(table: "notes", columns: t.columns, cells: values.map(DeckMemoryCloudSchema.cell),
            references: ["path": .init(storeId: store, table: "file", id: .init(type: "text", value: path))]))
        return try part(store: store, row: "I05", key: try DeckMemoryCloudSchema.key(t, values), body: body)
    }
    private func file(store: String, path: String) throws -> CloudOperation {
        try part(store: store, row: "I01", key: "file/" + path,
                 body: Data(("---\nid: n-\(UUID().uuidString)\n---\n# Note\n" + (0..<40).map { _ in UUID().uuidString }.joined(separator: " ") + "\n").utf8))
    }

    @Test func anArrivedFileReadsOnlyItsOwnWaitingLabels() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05")
        let store = UUID().uuidString.lowercased()
        let paths = (0..<60).map { "hoot/notes/arrived-\($0).md" }
        // 60 labels arrive before their files (the order the Mac mini's first copy had).
        _ = try await b.apply(try paths.map { try label(store: store, path: $0) }, row: "I05")
        var visits: [Int] = []
        for path in paths.prefix(10) {
            let before = await b.store.cloudRevisits
            _ = try await b.apply([try file(store: store, path: path)], row: "I01")
            visits.append(await b.store.cloudRevisits - before)
        }
        // Before: every file walked all labels still waiting (60, 59, 58 …).
        #expect(visits.allSatisfy { $0 <= 1 }, "\(visits)")
        await b.close()
    }
}
