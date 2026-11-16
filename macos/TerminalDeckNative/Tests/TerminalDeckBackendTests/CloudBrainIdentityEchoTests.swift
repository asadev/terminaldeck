import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-8b (review of MAC-NEXT-8): whether a version goes out is decided by IDENTITY, never by content. A version
/// this Mac made always goes, even when its bytes equal a version once received; a version received from another device
/// is never queued or sent as this Mac's own.
@Suite("Cloud brain — what this Mac made goes, what it received never goes back", .serialized)
struct CloudBrainIdentityEchoTests {
    static let otherStore = "bbe61469-0fb5-441c-bdac-2aa9258682c2"

    private func op(row: String, key: String, body: Data) throws -> (operation: CloudOperation, version: String, hash: String) {
        let version = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: Self.otherStore, inventoryRow: row, key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        let operation = CloudOperation(v: 1, opId: revision, originDevice: UUID().uuidString.lowercased(), domain: CloudBrainMemoryFormat.domain(row),
                                       entityId: BackendCloudBrainMemoryHash.uuid(Self.otherStore + "\n" + key + "\n0"), revision: revision, parents: [], kind: .put,
                                       source: .init(sourceId: "memory/" + row, recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                                       payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
        return (operation, version, hash)
    }
    private func parts(_ f: CloudBrainMemoryFixture, _ row: String) async throws -> [CloudBrainMemoryPart] {
        let adapter = try f.adapter(row)
        var cursor: String?, all: [CloudBrainMemoryPart] = []
        while let change = try await adapter.localChange(after: cursor) {
            all.append(try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(change.operation.payload)))
            cursor = change.cursor
        }
        return all
    }
    private func settle(_ f: CloudBrainMemoryFixture) async throws {
        try await f.store.cloudStartReconcile(full: true)
        var steps = 0
        while try await f.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
    }
    static let settingA: [DeckMemorySQL] = [.text("hoot"), .text("card.limit"), .text("12"), .real(1000.5)]
    static let settingB: [DeckMemorySQL] = [.text("hoot"), .text("card.limit"), .text("20"), .real(1001.5)]

    // MARK: A received, B made here, A made here again

    @Test func aSharedSettingChangedBackToAReceivedValueIsSentAndDescendsFromThisMacsEdit() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I05")
        let t = try DeckMemoryCloudSchema.table("settings")
        let a = try op(row: "I05", key: try DeckMemoryCloudSchema.key(t, Self.settingA), body: try DeckMemoryCloudSchema.encodeRow(t, Self.settingA))
        _ = try await b.apply([a.operation], row: "I05")
        try await settle(b)
        #expect(try await parts(b, "I05").isEmpty, "a received value re-read is never queued")
        try await b.store.cloudFixtureWriteSetting(Self.settingB)
        let afterB = try await parts(b, "I05")
        let sentB = try #require(afterB.last)
        #expect(sentB.parents == [a.version], "B descends from the received A")
        try await b.store.cloudFixtureWriteSetting(Self.settingA)
        let sentA = try #require(try await parts(b, "I05").last)
        #expect(sentA.resourceHash == a.hash, "the same bytes as the version once received")
        #expect(sentA.version != a.version && sentA.parents == [sentB.version], "a new version of this Mac's, after B: the other Mac ends on A")
        await b.close()
    }

    @Test func aSharedSettingDeletedAndMadeAgainWithTheSameValueIsSent() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I05")
        let t = try DeckMemoryCloudSchema.table("settings")
        let a = try op(row: "I05", key: try DeckMemoryCloudSchema.key(t, Self.settingA), body: try DeckMemoryCloudSchema.encodeRow(t, Self.settingA))
        _ = try await b.apply([a.operation], row: "I05")
        try await b.store.cloudFixtureDeleteSetting(owner: "hoot", key: "card.limit")
        try await b.store.cloudFixtureWriteSetting(Self.settingA)
        let sent = try await parts(b, "I05")
        #expect(sent.contains { $0.resourceHash == a.hash && $0.version != a.version }, "made again here: it goes")
        await b.close()
    }

    // MARK: files (a note, a topic, a memory document)

    @Test(arguments: ["hoot/notes/n-identity.md", "hoot/topics/t-identity.md", "hoot/guide.md"])
    func aFileChangedBackToAReceivedTextIsSent(_ path: String) async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05")
        let textA = path.contains("/notes/") ? "---\nid: n-identity\ndate: 2026-11-13T09:00:00Z\nseat: hoot\ntype: note\n---\n# A\nFrom the other Mac.\n"
            : path.contains("/topics/") ? "---\nid: t-identity\ndate: 2026-11-13T09:00:00Z\nseat: hoot\n---\n# Topic\nA.\n" : "# Guide\nA.\n"
        let a = try op(row: "I01", key: "file/" + path, body: Data(textA.utf8))
        _ = try await b.apply([a.operation], row: "I01")
        try await settle(b)
        #expect(try await parts(b, "I01").isEmpty, "a received file re-read is never queued")
        try b.write(path, textA + "B, written here.\n")
        try await settle(b)
        let sentB = try #require(try await parts(b, "I01").last)
        #expect(sentB.parents == [a.version])
        try b.write(path, textA)
        try await settle(b)
        let sentA = try #require(try await parts(b, "I01").last)
        #expect(sentA.resourceHash == a.hash && sentA.version != a.version && sentA.parents == [sentB.version], "\(path): A made here goes, after B")
        await b.close()
    }

    @Test func aReceivedFileDeletedAndWrittenAgainWithTheSameTextIsSent() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05")
        let path = "hoot/guide.md", text = "# Guide\nA.\n"
        let a = try op(row: "I01", key: "file/" + path, body: Data(text.utf8))
        _ = try await b.apply([a.operation], row: "I01")
        try FileManager.default.removeItem(at: b.root.appendingPathComponent(path))
        try await settle(b)
        // Phase 1 of the one rule (lane memory-one-rule): removals are not sent until every Mac of the account
        // understands them (`cloudOneRuleSends`); with sending on they travel (CloudMemoryOneRuleTests).
        #expect(try await parts(b, "I01").isEmpty, "a removal sends nothing in phase 1")
        // Delete rule (Asad 14 Nov; 824bd036c): a by-hand removal stays on this Mac (absence is local state, the
        // last-seen row is kept). The same text written again is what the Cloud already holds: the mark clears and
        // nothing is sent (no echo, and no removal ever left this Mac, so the other device keeps it).
        try b.write(path, text)
        try await settle(b)
        #expect(try await parts(b, "I01").isEmpty, "the same text again: nothing to send, nothing removed elsewhere")
        #expect(try String(contentsOf: b.root.appendingPathComponent(path), encoding: .utf8) == text)
        // His own new words after that still go (the guard this test was written for: work made here is never swallowed).
        let newer = text + "Written again here, changed.\n"
        try b.write(path, newer)
        try await settle(b)
        let sent = try await parts(b, "I01")
        #expect(sent.contains { $0.resourceHash == DeckMemoryFiles.hash(Data(newer.utf8)) && $0.version != a.version }, "a change made here goes")
        await b.close()
    }

    /// The queue side of the 345: a "kept both" sibling holds an OLDER received version of a record (its newer
    /// version is the live row). A full reconcile (the launch pass after an unclean quit) never queues it.
    @Test func olderReceivedVersionsKeptBesideTheLiveRowAreNeverQueued() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I05")
        let t = try DeckMemoryCloudSchema.table("questions")
        var ops: [CloudOperation] = []
        for n in 0..<6 {
            // Same question id, unrelated versions (no parents): each one after the first is kept beside it.
            let values: [DeckMemorySQL] = [.int(7), .text("hoot"), .text("Keep this? \(n)"), .text("ctx"), .text("[]"), .real(1000.5 + Double(n)), .null, .null, .null]
            ops.append(try op(row: "I05", key: try DeckMemoryCloudSchema.key(t, values), body: try DeckMemoryCloudSchema.encodeRow(t, values)).operation)
        }
        for o in ops { _ = try await b.apply([o], row: "I05") }
        #expect(try await b.store.cloudFixtureCount("questions") >= 2, "versions were kept beside each other")
        try await settle(b)
        #expect(try await parts(b, "I05").isEmpty, "no received version goes back")
        await b.close()
    }
}

extension DeckMemoryStore {
    /// Writes a settings row exactly (the app's own writer stamps `updated` with now).
    func cloudFixtureWriteSetting(_ values: [DeckMemorySQL]) throws {
        try db.run("INSERT INTO settings(owner,key,value,updated) VALUES (?,?,?,?) ON CONFLICT(owner,key) DO UPDATE SET value=excluded.value,updated=excluded.updated", values)
    }
    func cloudFixtureDeleteSetting(owner: String, key: String) throws {
        try db.run("DELETE FROM settings WHERE owner=? AND key=?", [.text(owner), .text(key)])
    }
}
