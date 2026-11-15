import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// His own text beats an untouched app default (Decker, 14 Nov, under the owner's one rule).
///
/// His Macs on 14 Nov: the Mac mini (A) had his own Hoot playbook and lead settings; the MacBook (B) had the app's
/// untouched defaults, sent as its first copy two minutes after A's. The MacBook rightly took his texts when it joined
/// (first-join path: a local default never stands against an arrival). The Mac mini had kept B's default as a second
/// copy (`archive/cloud-conflicts/...`, an older build); the one-time settling decided by stamp and put the default in
/// use over his text. Each Mac then held the other's text. Real memory stores on scratch folders; written unbuilt.
@Suite("Cloud memory — his own text beats an untouched app default")
struct CloudMemoryDefaultRuleTests {
    static let playbook = "hoot/playbook.md"
    static let his = "# Playbook\nRead notes before working.\n| Job | AI |\n|---|---|\n| release | claude |\n"
    static var shippedPlaybook: String { DeckMemoryFiles.playbookText(preface: "", rows: [.init(jobKind: "default")], trailer: "") }

    private func text(_ f: CloudBrainMemoryFixture, _ path: String) -> String? { try? String(contentsOf: f.root.appendingPathComponent(path), encoding: .utf8) }
    private func changes(_ f: CloudBrainMemoryFixture, _ row: String) async throws -> [CloudOperation] {
        let adapter = try f.adapter(row)
        var cursor: String?, out: [CloudOperation] = [], seen = Set<String>()
        while let change = try await adapter.localChange(after: cursor) {
            if seen.insert(change.operation.opId).inserted { out.append(change.operation) }
            cursor = change.cursor
        }
        return out
    }
    /// A holds `aText` at `path`, B holds `bText`; both send first copies (B's stamped two minutes later); B joins
    /// (A's first copy arrives on B), then B's first copy arrives on A.
    private func macs(_ path: String, a aText: String, b bText: String) async throws -> (a: CloudBrainMemoryFixture, b: CloudBrainMemoryFixture, bStore: String) {
        try await macs([(path, aText, bText)])
    }
    private func macs(_ files: [(path: String, a: String, b: String)]) async throws -> (a: CloudBrainMemoryFixture, b: CloudBrainMemoryFixture, bStore: String) {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        await a.store.cloudSetClock { 1_000 }
        await b.store.cloudSetClock { 121_000 }
        try await a.seed()
        for f in files { try a.write(f.path, f.a) }
        _ = try await a.store.reindex()
        try await b.store.start()
        for f in files { try b.write(f.path, f.b) }
        _ = try await b.store.reindex()
        for f in [a, b] { await f.store.cloudSetDevice(f.deviceId); await f.store.cloudSetOneRuleSending(true) }
        let aFirst = try await a.snapshot("I01").operations
        let bFirst = try await b.snapshot("I01").operations
        _ = try await b.apply(aFirst, row: "I01")
        _ = try await a.apply(bFirst, row: "I01")
        try await a.store.oneRuleFixtureCaptureAll(); try await b.store.oneRuleFixtureCaptureAll()
        return (a, b, try await b.store.cloudStoreId())
    }

    // The rule in the clean-up and in the normal newest-text choice. Before the rule (cb7a961d2 and earlier) A put B's
    // default in use at both points: B's stamp is later, as the first expectation shows.
    @Test func theCleanUpAndTheNewestChoiceNeverPutTheDefaultOverHisText() async throws {
        let (a, b, bStore) = try await macs(Self.playbook, a: Self.his, b: Self.shippedPlaybook)
        #expect(text(b, Self.playbook) == Self.his, "first join: B's untouched default gave way to his text")
        #expect(try await a.store.defaultRuleFixtureStampPicksOther(Self.playbook, other: bStore), "by stamp alone B's default would win")
        #expect(text(a, Self.playbook) == Self.his, "normal newest-text choice: his text stays")
        // The older build's state: B's default kept beside it as a second copy; the one-time settling runs.
        let copy = try await a.store.defaultRuleFixtureOldCopy(Self.playbook, other: bStore)
        for _ in 0..<12 { _ = try await a.store.cloudOneRuleStep(limit: 4) }
        #expect(!FileManager.default.fileExists(atPath: a.root.appendingPathComponent(copy).path), "the second copy left")
        #expect(text(a, Self.playbook) == Self.his, "the clean-up kept his text in use")
        #expect(try await a.store.oneRuleFixtureKeptTexts().contains(Self.shippedPlaybook), "the default is kept as a version")
        await a.close(); await b.close()
    }

    // The repair on a store the clean-up already flipped (his Mac mini): his text back, the default kept, B stays on
    // his text, at most one record for the file, never again.
    @Test func theRepairPutsHisTextBackOnceAndTheOtherMacLinesUp() async throws {
        let (a, b, bStore) = try await macs(Self.playbook, a: Self.his, b: Self.shippedPlaybook)
        try await a.store.defaultRuleFixtureOldOutcome(Self.playbook, his: Self.his, other: bStore)
        #expect(text(a, Self.playbook) == Self.shippedPlaybook, "the Mac mini's state on 14 Nov")
        let before = try await a.store.defaultRuleFixtureJournal("file/" + Self.playbook)
        for _ in 0..<12 { _ = try await a.store.cloudOneRuleStep(limit: 4) }
        #expect(text(a, Self.playbook) == Self.his, "his text is in use again")
        #expect(try await a.store.oneRuleFixtureKeptTexts().contains(Self.shippedPlaybook), "the default stays as a kept version")
        let sent = try await a.store.defaultRuleFixtureJournal("file/" + Self.playbook)
        #expect(sent == before + 1, "one record for the file")
        // B, already on his text, lines up and never flips.
        _ = try await b.apply(try await changes(a, "I01"), row: "I01")
        for _ in 0..<4 { _ = try await b.store.cloudOneRuleStep(limit: 4) }
        #expect(text(b, Self.playbook) == Self.his)
        // A second run does nothing; ten further passes send nothing more.
        #expect(try await a.store.cloudRepairDefaultInUse() == 0)
        for _ in 0..<10 {
            _ = try await a.store.cloudOneRuleStep(limit: 4)
            try await a.store.oneRuleFixtureCaptureAll()
        }
        #expect(try await a.store.defaultRuleFixtureJournal("file/" + Self.playbook) == sent, "nothing more was sent")
        #expect(text(a, Self.playbook) == Self.his)
        await a.close(); await b.close()
    }

    // Review (14 Nov): one file that fails never stops the repair. The second file's kept text is unreadable: the first
    // is put back, the repair is marked done (the failure named), the archived settling after it runs, a second start
    // does nothing.
    @Test func aFileThatFailsNeverStopsTheRepairAndTheNextStepRuns() async throws {
        let lead = "templates/lead/settings.md"
        let shippedLead = DeckMemoryStore.templateSettingsText(DeckMemoryStore.defaultTemplate(.lead))
        let hisLead = shippedLead.replacingOccurrences(of: "- helper model: sonnet", with: "- helper model: fixture-own-model")
        #expect(hisLead != shippedLead)
        let (a, b, bStore) = try await macs([(Self.playbook, Self.his, Self.shippedPlaybook), (lead, hisLead, shippedLead)])
        try await a.store.defaultRuleFixtureOldOutcome(Self.playbook, his: Self.his, other: bStore)
        try await a.store.defaultRuleFixtureOldOutcome(lead, his: hisLead, other: bStore)
        try await a.store.defaultRuleFixtureBreakKept(hisLead)
        let lines = DefaultRuleLines()
        CloudSyncDiagnostics.shared.setSink { lines.add($0) }
        defer { CloudSyncDiagnostics.shared.setSink(nil) }
        for _ in 0..<12 { _ = try await a.store.cloudOneRuleStep(limit: 4) }
        #expect(text(a, Self.playbook) == Self.his, "the first file is put back")
        #expect(text(a, lead) == shippedLead, "the failed file is left as it is")
        #expect(try await a.store.defaultRuleFixtureRepairDone(), "marked done despite the failure")
        #expect(try await a.store.memoryOneRuleReport().phase2Finished, "the archived settling after it ran")
        let said = lines.snapshot()
        #expect(said.contains { $0.contains(lead) && $0.contains("could not be put back") }, "\(said)")
        #expect(said.contains { $0.contains("could not put back: " + lead) }, "the final line names it")
        #expect(!said.contains { $0.contains("could not") && $0.contains("helper model") }, "never the text")
        // A second start: nothing runs again.
        #expect(try await a.store.cloudRepairDefaultInUse() == 0)
        await a.close(); await b.close()
    }

    // Two texts of his (neither a default): the repair never touches them (the Cloud's history decided).
    @Test func twoNonDefaultTextsAreNotTouchedByTheRepair() async throws {
        let other = "# Playbook\nThe MacBook's own rows.\n"
        let (a, b, bStore) = try await macs(Self.playbook, a: Self.his, b: other)
        try await a.store.defaultRuleFixtureOldOutcome(Self.playbook, his: Self.his, other: bStore)
        #expect(text(a, Self.playbook) == other)
        for _ in 0..<12 { _ = try await a.store.cloudOneRuleStep(limit: 4) }
        #expect(text(a, Self.playbook) == other, "not a default in use: left as it is")
        await a.close(); await b.close()
    }

    // A kept version that is itself a shipped default (an earlier default text) is never put back.
    @Test func aKeptVersionThatIsItselfADefaultIsNotPutBack() async throws {
        let path = "templates/agent/checklist.md"
        let fresh = DeckMemoryStore.defaultTemplate(.agent).checklist, flow = DeckMemoryFlowChecklist.defaultText
        #expect(fresh != flow, "two different shipped defaults for this file")
        let (a, b, bStore) = try await macs(path, a: flow, b: fresh)
        try await a.store.defaultRuleFixtureOldOutcome(path, his: flow, other: bStore)
        #expect(text(a, path) == fresh)
        for _ in 0..<12 { _ = try await a.store.cloudOneRuleStep(limit: 4) }
        #expect(text(a, path) == fresh, "a default never replaces a default through the repair")
        await a.close(); await b.close()
    }
}

final class DefaultRuleLines: @unchecked Sendable {
    private let lock = NSLock(); private var all: [String] = []
    func add(_ line: String) { lock.withLock { all.append(line) } }
    func snapshot() -> [String] { lock.withLock { all } }
}

extension DeckMemoryStore {
    /// The kept text's bytes are gone (a damaged keeper): using that version fails.
    func defaultRuleFixtureBreakKept(_ text: String) throws {
        try FileManager.default.removeItem(at: cloudKeeper().contentURL(kind: Self.oneRuleKind, sha256: BackendCloudBrainMemoryHash.bytes(Data(text.utf8))))
    }
    func defaultRuleFixtureRepairDone() throws -> Bool {
        try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(Self.defaultRepairKey)])?.string(0) == "done"
    }
    private func defaultRuleFixtureVersions(_ path: String, other: String) throws -> (own: String, ownHash: String, other: String, otherHash: String) {
        let key = "file/" + path, own = try cloudStoreId()
        guard let mine = try db.first("SELECT revision,content_hash FROM cloud_memory_versions WHERE store_id=? AND resource_key=? ORDER BY rowid LIMIT 1", [.text(own), .text(key)]),
              let theirs = try db.first("SELECT revision,content_hash FROM cloud_memory_versions WHERE store_id=? AND resource_key=? ORDER BY rowid LIMIT 1", [.text(other), .text(key)]) else {
            throw CloudFailure.unavailable
        }
        return (mine.text(0), mine.text(1), theirs.text(0), theirs.text(1))
    }
    /// True when the stamp rule alone (`winner`) picks the other Mac's first copy over this Mac's.
    func defaultRuleFixtureStampPicksOther(_ path: String, other: String) throws -> Bool {
        let v = try defaultRuleFixtureVersions(path, other: other), key = "file/" + path
        guard let mine = try cloudRevision(storeId: cloudStoreId(), key: key, version: v.own),
              let theirs = try cloudRevision(storeId: other, key: key, version: v.other) else { throw CloudFailure.unavailable }
        return DeckMemoryCloudMerge.winner(theirs, mine).version == theirs.version
    }
    /// What an older build left: the other Mac's version kept beside the file as `archive/cloud-conflicts/...`.
    func defaultRuleFixtureOldCopy(_ path: String, other: String) throws -> String {
        let v = try defaultRuleFixtureVersions(path, other: other), key = "file/" + path
        guard let bytes = cloudKnownBytes(hash: v.otherHash, stores: [other]) else { throw CloudFailure.unavailable }
        let copy = "archive/cloud-conflicts/" + other + "/" + v.otherHash + "/" + path
        try FileManager.default.createDirectory(at: url(copy).deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url(copy), options: .atomic)
        try db.run("UPDATE cloud_memory_versions SET projection=?,projected_hash=? WHERE store_id=? AND resource_key=? AND revision=?",
                   [.text(copy), .text(v.otherHash), .text(other), .text(key), .text(v.other)])
        try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET store_id=excluded.store_id,resource_key=excluded.resource_key,version=excluded.version",
                   [.text(copy), .text(other), .text(key), .text(v.other)])
        try db.run("INSERT INTO cloud_memory_files(path,hash) VALUES (?,?) ON CONFLICT(path) DO UPDATE SET hash=excluded.hash", [.text(copy), .text(v.otherHash)])
        _ = try reindexNow(paths: [copy])
        return copy
    }
    /// What the settling did before the rule on his Mac mini: his text kept with its revision, the other Mac's version
    /// (recorded as a former second copy) in use at `path`, the bookkeeping saying nothing is to be sent.
    func defaultRuleFixtureOldOutcome(_ path: String, his: String, other: String) throws {
        let v = try defaultRuleFixtureVersions(path, other: other), key = "file/" + path, own = try cloudStoreId()
        guard let bytes = cloudKnownBytes(hash: v.otherHash, stores: [other]) else { throw CloudFailure.unavailable }
        let copy = "archive/cloud-conflicts/" + other + "/" + v.otherHash + "/" + path
        try db.run("UPDATE cloud_memory_versions SET projection=?,projected_hash=? WHERE store_id=? AND resource_key=? AND revision=?",
                   [.text(copy), .text(v.otherHash), .text(other), .text(key), .text(v.other)])
        try cloudKeepText(path: path, content: Data(his.utf8), ref: .init(storeId: own, key: key, version: v.own), at: nil, device: nil)
        try bytes.write(to: url(path), options: .atomic)
        try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET store_id=excluded.store_id,resource_key=excluded.resource_key,version=excluded.version",
                   [.text(path), .text(other), .text(key), .text(v.other)])
        try db.run("INSERT INTO cloud_memory_files(path,hash) VALUES (?,?) ON CONFLICT(path) DO UPDATE SET hash=excluded.hash", [.text(path), .text(v.otherHash)])
        if let p = try cloudStoredPart(storeId: other, key: key, version: v.other) { try cloudWriteImportHead(p) }
        _ = try reindexNow(paths: [path])
    }
    func defaultRuleFixtureJournal(_ key: String) throws -> Int {
        Int(try db.first("SELECT COUNT(*) FROM cloud_memory_journal WHERE resource_key=?", [.text(key)])?.int(0) ?? 0)
    }
}
