import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-5 (13 Nov, the joining MacBook): the Mac mini's memory arrived first (57,000 records) and its projects and
/// agents last, so 40,728 rows waited for a project; they waited for a FOLDER the person was never asked for; and every
/// arrived memory file walked all of them again (one file per 20 s at 100 % CPU, fetching stalled).
@Suite("Cloud brain — memory follows its project's record; work per arrived file stays flat", .serialized)
struct CloudBrainJoinOrderTests {
    private func makeOp(row: String, key: String, body: Data) throws -> CloudOperation {
        let store = UUID().uuidString.lowercased(), version = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let payload = CloudBrainMemoryPart(storeId: store, inventoryRow: row, key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        return CloudOperation(v: 1, opId: revision, originDevice: UUID().uuidString.lowercased(), domain: CloudBrainMemoryFormat.domain(row),
                              entityId: BackendCloudBrainMemoryHash.uuid(store + "\n" + key + "\n0"), revision: revision, parents: [], kind: .put,
                              source: .init(sourceId: "memory/" + row, recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                              payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
    }
    private func setting(owner: String) throws -> CloudOperation {
        let t = try DeckMemoryCloudSchema.table("settings")
        let values: [DeckMemorySQL] = [.text(owner), .text("card.limit"), .text("9999"), .real(1000.5)]
        return try makeOp(row: "I05", key: try DeckMemoryCloudSchema.key(t, values), body: try DeckMemoryCloudSchema.encodeRow(t, values))
    }
    /// Text that barely compresses, like the owner's memory files.
    private func file(_ path: String) throws -> CloudOperation {
        try makeOp(row: "I01", key: "file/" + path, body: Data(("# Note\n" + (0..<40).map { _ in UUID().uuidString }.joined(separator: " ") + "\n").utf8))
    }

    @Test func eachArrivedFileCostsTheSameHoweverManyRowsWaitAndAProjectReleasesOnlyItsOwn() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I01"); try await b.activate("I05")
        _ = try await b.store.cloudUseLeanProjectRule()
        // 600 rows of 60 projects this Mac does not know yet.
        for batch in 0..<6 {
            _ = try await b.apply(try (0..<100).map { try setting(owner: "project:far-\(batch * 10 + $0 % 10)-\($0)") }, row: "I05")
        }
        #expect(try await b.store.cloudWaitingCount() == 600)
        // Files keep arriving: no waiting row is visited again for any of them (before: all 600 for each file).
        var visits: [Int] = []
        for index in 0..<20 {
            let before = await b.store.cloudRevisits
            _ = try await b.apply([try file("hoot/notes/arrived-\(index).md")], row: "I01")
            visits.append(await b.store.cloudRevisits - before)
        }
        #expect(visits.allSatisfy { $0 == 0 }, "\(visits)")
        // One project becomes known: only its own row is read and placed, in one pass.
        let known = KnownProjects()
        _ = try await b.store.cloudUseLeanProjectRule(then: { incoming, _ in known.has(incoming) ? incoming : nil })
        known.add("far-0-0")
        let before = await b.store.cloudRevisits
        #expect(try await b.store.cloudRetryWaitingProjects() == 1)
        #expect(await b.store.cloudRevisits - before == 1)
        for batch in 0..<6 { for i in 0..<100 { known.add("far-\(batch * 10 + i % 10)-\(i)") } }
        #expect(try await b.store.cloudRetryWaitingProjects() == 599)
        #expect(try await b.store.cloudWaitingCount() == 0)
        await b.close()
    }

    @Test func memoryThatArrivesBeforeItsProjectIsMergedWhenTheRecordArrivesWithNoFolderChosen() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock)
        let mem = try CloudBrainMemoryFixture()
        let bMac = try CloudLeanFixture.mac(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: bMac.root) }
        try await mem.activate("I01"); try await mem.activate("I05")
        // The joining Mac's project owner tells its memory to place what waited, as the app's wiring does.
        let registry = BackendPROJRegistry(fileURL: bMac.root.appendingPathComponent("projects.registry.json"), changed: { _ in })
        let owner = BackendCloudLeanProjects(registry: registry, memory: { _ = try? await mem.store.cloudRetryWaitingProjects() })
        let adapter = try owner.adapter(store: bMac.store, account: bMac.account, origins: bMac.origins)
        _ = try await mem.store.cloudUseLeanProjectRule(then: owner.memoryResolver())
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", folders: ["/Users/person-a/Code/deck"], colour: "teal"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([adapter], on: bMac)

        // Memory first (the order the Mac mini's first copy had): it waits, untouched.
        _ = try await mem.apply(try (0..<30).map { try file("projects/deck/notes/n\($0).md") }, row: "I01")
        _ = try await mem.apply([try setting(owner: "project:deck")], row: "I05")
        #expect(try await mem.store.cloudWaitingCount() == 31)
        #expect(!FileManager.default.fileExists(atPath: mem.root.appendingPathComponent("projects/deck/notes/n0.md").path))

        // The project's record arrives last: everything is merged at once, with no folder chosen and no click.
        _ = try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: adapter)
        #expect(try await mem.store.cloudWaitingCount() == 0)
        #expect(FileManager.default.fileExists(atPath: mem.root.appendingPathComponent("projects/deck/notes/n29.md").path))
        #expect(try await mem.store.value("card.limit", owner: .project("deck")) == "9999")
        let arrived = try await registry.projects().first { $0.id == "deck" }
        #expect(arrived?.folders == [], "No folder was chosen")
        await mem.close()
    }

    private final class KnownProjects: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
        func has(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    }
}
