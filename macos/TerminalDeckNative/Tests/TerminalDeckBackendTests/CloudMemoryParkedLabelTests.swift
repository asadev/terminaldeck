import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Parked memory (14 Nov, the owner's MacBook): two arriving `brain/memory/i05` records sat parked all day with
/// "This Mac could not take this record (invalidRequest)". They were entries of memory's file list (`files` table:
/// path, kind, owner) that the Mac mini sent at 05:26Z, when the one-rule settling took away its two second copies
/// (`archive/cloud-conflicts/<MacBook store>/<hash>/hoot/playbook.md` and `.../templates/lead/settings.md`). Each copy's
/// list entry had ARRIVED from the MacBook under the first file's record (`row/files/<hash of "hoot/playbook.md">`) and
/// was placed at the copy's place; with the copy's file origin gone, the re-indexed entry went out under that record's
/// name with the copy's path inside. The MacBook's check "the record's name is its content's key" refused it.
/// Exact shapes from his MacBook's `parked_ops` (ids and paths only, no note text).
@Suite("Cloud memory — a list entry under another file's name is kept, never refused")
struct CloudMemoryParkedLabelTests {
    static let playbook = "hoot/playbook.md"

    /// Two Macs holding the seeded memory, B joined from A's first copy (as `CloudMemoryOneRuleTests.pair`).
    private func pair() async throws -> (CloudBrainMemoryFixture, CloudBrainMemoryFixture) {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed()
        try await b.store.start()
        for row in ["I01", "I05", "I06"] {
            try await b.activate(row)
            _ = try await b.apply(try await a.snapshot(row).operations, row: row)
        }
        return (a, b)
    }
    static func cell(_ text: String) -> CloudBrainMemoryCell { .init(type: "text", value: text) }
    static func filesKey(_ path: String) throws -> String {
        "row/files/" + DeckMemoryFiles.hash(try CloudWire.canonical([cell(path)]))
    }
    static func conflictPath(_ store: String, _ path: String) -> String {
        "archive/cloud-conflicts/" + store + "/" + String(repeating: "9", count: 64) + "/" + path
    }
    /// The record exactly as the Mac mini sent it: the record is the first file's list entry (and the RECEIVER's own
    /// store, as on his MacBook), its content names the copy's place, its path reference names the sender's store.
    static func misnamedEntry(receiverStore: String, senderStore: String, senderDevice: String) throws -> CloudOperation {
        let conflict = conflictPath(receiverStore, playbook)
        let row = CloudBrainMemoryRow(table: "files", columns: ["path", "kind", "owner"],
                                      cells: [cell(conflict), cell("playbook"), cell("hoot")],
                                      references: ["path": .init(storeId: senderStore, table: "file", id: cell(conflict))])
        let body = try CloudWire.canonical(row)
        let key = try filesKey(playbook)
        let version = UUID().uuidString.lowercased(), parentVersion = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: receiverStore, inventoryRow: "I05", key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, parents: [parentVersion], data: body.base64EncodedString(),
                                           stamp: "1794633996249", baseline: false)
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let opId = DeckMemoryStore.cloudOperationId(version: version, index: 0, device: senderDevice)
        let parentOp = DeckMemoryStore.cloudOperationId(version: parentVersion, index: 0, device: senderDevice)
        return CloudOperation(v: 1, opId: opId, originDevice: senderDevice, domain: CloudBrainMemoryFormat.domain("I05"),
                              entityId: BackendCloudBrainMemoryHash.uuid(receiverStore + "\n" + key + "\n0"), revision: opId, parents: [parentOp], kind: .put,
                              source: .init(sourceId: "memory/I05", recordId: key, offset: 0, rawHash: hash), createdAt: 1_794_633_997_896,
                              payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
    }

    // Receiver. Before: `invalidRequest` (parked for good, the line said "refused"). After: taken as history only;
    // nothing of the receiver's list or files changes; taking it again is the same answer (the parked retry at start).
    @Test func theMisnamedListEntryIsKeptAsHistoryAndChangesNothing() async throws {
        let (a, b) = try await pair()
        let bStore = try await b.store.cloudStoreId(), aStore = try await a.store.cloudStoreId()
        let entry = try Self.misnamedEntry(receiverStore: bStore, senderStore: aStore, senderDevice: a.deviceId)
        let filesBefore = try await b.store.parkedFixtureFiles()
        let playbookBefore = try String(contentsOf: b.root.appendingPathComponent(Self.playbook), encoding: .utf8)
        let blockedBefore = try await b.store.cloudMemoryReadiness().counts.blocked

        let receipt = try await b.apply([entry], row: "I05")
        #expect(receipt.results.map(\.status) == [.alreadyPresent])
        #expect(try await b.store.parkedFixtureFiles() == filesBefore, "the file list is unchanged")
        #expect(try await b.store.parkedFixtureFiles().contains { $0.hasPrefix("archive/cloud-conflicts/") } == false)
        #expect(try String(contentsOf: b.root.appendingPathComponent(Self.playbook), encoding: .utf8) == playbookBefore)
        #expect(try await b.store.cloudMemoryReadiness().counts.blocked == blockedBefore, "kept as history, never an unfinished import")
        // A retry (at the next start every parked arrival is tried again) gives the same answer.
        let again = try await b.apply([entry], row: "I05")
        #expect(again.results.map(\.status) == [.alreadyPresent])
        await a.close(); await b.close()
    }

    // A row of any other table whose name and content disagree is still refused.
    @Test func aMisnamedRowOfAnotherTableIsStillRefused() async throws {
        let (a, b) = try await pair()
        let bStore = try await b.store.cloudStoreId()
        let t = try DeckMemoryCloudSchema.table("meta")
        let body = try CloudWire.canonical(CloudBrainMemoryRow(table: t.name, columns: t.columns, cells: [Self.cell("fixture.key"), Self.cell("v")], references: [:]))
        let key = "row/meta/" + DeckMemoryFiles.hash(try CloudWire.canonical([Self.cell("another.key")]))
        let version = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: bStore, inventoryRow: "I05", key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let opId = DeckMemoryStore.cloudOperationId(version: version, index: 0, device: a.deviceId)
        let op = CloudOperation(v: 1, opId: opId, originDevice: a.deviceId, domain: CloudBrainMemoryFormat.domain("I05"),
                                entityId: BackendCloudBrainMemoryHash.uuid(bStore + "\n" + key + "\n0"), revision: opId, parents: [], kind: .put,
                                source: .init(sourceId: "memory/I05", recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                                payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
        await #expect(throws: CloudFailure.invalidRequest) { _ = try await b.apply([op], row: "I05") }
        await a.close(); await b.close()
    }

    // Sender. The Mac mini's state after the settling: a list entry at the copy's place whose origin is the other
    // Mac's first-file entry, and no file origin for the copy any more. Before: it rebuilt into the misnamed record
    // and went out. After: it is this Mac's index of a file that is gone, never sent.
    @Test func theSenderNeverSendsAListEntryWhoseNameAndPlaceDisagree() async throws {
        let (a, b) = try await pair()
        let bStore = try await b.store.cloudStoreId()
        let conflict = Self.conflictPath(bStore, Self.playbook)
        let firstFileKey = try Self.filesKey(Self.playbook)
        let decided = try await a.store.parkedFixtureSettledCopyEntry(conflict: conflict, originStore: bStore, originKey: firstFileKey,
                                                                       originalPath: Self.playbook)
        #expect(decided.key == firstFileKey, "the shape his Mac mini sent: the first file's record name")
        #expect(decided.path == conflict, "with the copy's place inside")
        #expect(decided.echo, "never sent")
        // An ordinary list entry of this Mac is still sent.
        #expect(try await a.store.parkedFixtureOrdinaryEntryIsEcho(Self.playbook) == false)
        await a.close(); await b.close()
    }
}

extension DeckMemoryStore {
    func parkedFixtureFiles() throws -> [String] { try db.rows("SELECT path FROM files ORDER BY path").map { $0.text(0) } }
    /// Builds the Mac mini's settled-copy list entry (row + origin, no file origin) and asks what the capture would do.
    func parkedFixtureSettledCopyEntry(conflict: String, originStore: String, originKey: String, originalPath: String) throws -> (key: String, path: String, echo: Bool) {
        let t = try DeckMemoryCloudSchema.table("files")
        let values: [DeckMemorySQL] = [.text(conflict), .text("playbook"), .text("hoot")]
        try db.run("INSERT OR REPLACE INTO files(path,kind,owner,mtime,bytes,hash,missing) VALUES (?,?,?,0,0,'',1)", values)
        try db.run("INSERT OR REPLACE INTO cloud_memory_origins(table_name,native_key,store_id,resource_key,original_keys,version) VALUES (?,?,?,?,?,?)",
                   [.text("files"), .text(try DeckMemoryCloudSchema.nativeKey(t, values)), .text(originStore), .text(originKey),
                    .blob(try CloudWire.canonical([CloudBrainMemoryCell(type: "text", value: originalPath)])), .text(UUID().uuidString.lowercased())])
        try db.run("DELETE FROM cloud_memory_file_origins WHERE path=?", [.text(conflict)])
        let own = try cloudStoreId()
        let resource = try cloudLogicalRow(t, values: values, database: db, storeId: own, sequence: 1, row: "I05")
        let (_, logical) = try DeckMemoryCloudSchema.decodeRow(resource.data ?? Data())
        guard case .text(let path) = logical[0] else { throw CloudFailure.invalidRequest }
        return (resource.key, path, try cloudIsEcho(resource, table: t, values: values, database: db, storeId: own))
    }
    func parkedFixtureOrdinaryEntryIsEcho(_ path: String) throws -> Bool {
        let t = try DeckMemoryCloudSchema.table("files")
        guard let row = try db.first("SELECT path,kind,owner FROM files WHERE path=?", [.text(path)]) else { throw CloudFailure.unavailable }
        let values = row.values
        let own = try cloudStoreId()
        try db.run("DELETE FROM cloud_memory_file_origins WHERE path=?", [.text(path)])
        let resource = try cloudLogicalRow(t, values: values, database: db, storeId: own, sequence: 2, row: "I05")
        return try cloudIsEcho(resource, table: t, values: values, database: db, storeId: own)
    }
}
