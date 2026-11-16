import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only. Never resolves the installed data folder, provider homes, Keychain, session host or a URL.
struct CloudBrainMemoryFixture: Sendable {
    static var approvedRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112", isDirectory: true).resolvingSymlinksInPath() }
    let base: URL
    let root: URL
    let store: DeckMemoryStore
    let deviceId: String
    init(now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000.125) }, embedder: (any DeckMemoryEmbedding)? = nil) throws {
        deviceId = UUID().uuidString.lowercased()
        base = Self.approvedRoot.appendingPathComponent("a-memory-" + UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("Memory")
        store = try DeckMemoryStore(root: root, dataRoot: base.appendingPathComponent("Data"), embedder: embedder, watch: false, now: now)
    }
    /// The account's own folder: every Cloud table and copy lives here, never in the memory folder or memory.db.
    var stateRoot: URL { base.appendingPathComponent("Data/cloud/" + String(repeating: "f", count: 64) + "/memory", isDirectory: true) }
    var snapshotRoot: URL { stateRoot.appendingPathComponent("snapshots", isDirectory: true) }
    func adapter(_ row: String) throws -> BackendCloudBrainMemory {
        try .init(store: store, deviceId: deviceId, inventoryRow: row, snapshotRoot: snapshotRoot)
    }
    /// Capture on (attach + TEMP triggers), as the activation step does before any cut.
    func capture() async throws { try await store.cloudResumeCapture(stateRoot: stateRoot) }
    func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func seed() async throws {
        try write("hoot/card.md", "# Card\nKeep all history.\n")
        try write("hoot/playbook.md", "# Playbook\nRead notes before working.\n")
        try write("hoot/notes/a.md", "---\nid: n-fixture-a\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Note\nA retained decision.\n")
        try write("hoot/topics/t.md", "---\nid: t\ndate: 1970-01-01T00:16:40Z\nseat: hoot\n---\n# Topic\nCurrent work.\n")
        try write("templates/agent/card.md", "# Shared card\nCheck the existing context.\n")
        try write("hoot/handoffs/h.md", "---\nid: h-fixture\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntitle: Handoff\n---\nNext step remains available.\n")
        try write("archive/versions/hoot/card.old.md", "Old card kept forever.\n")
        try write("archive/hoot/notes/old.md", "---\nid: n-fixture-old\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Old note\nArchived decision.\n")
        _ = try await store.reindex()
        _ = try await store.appendDiary([
            .init(stamp: .hoot, role: .user, text: "same words", externalID: "one"),
            .init(stamp: .hoot, role: .assistant, text: "same words", externalID: "two"),
            .init(stamp: .hoot, role: .tool, text: "<private>fixture private text</private>", externalID: "three"),
            .init(stamp: .hoot, role: .assistant, text: "A rewound message remains.", externalID: "four")
        ])
        try await store.cloudFixtureSeedRows()
        try await store.cloudFixtureBackup()
    }
    func snapshot(_ row: String, cut: String = UUID().uuidString) async throws -> (operations: [CloudOperation], coverage: CloudCoverage) {
        try await capture()
        let adapter = try adapter(row)
        var operations: [CloudOperation] = [], coverage: CloudCoverage?
        for try await page in await adapter.snapshotPages(cut: .init(snapshotId: cut, at: 1000125, watermarks: [:])) {
            operations += page.operations
            if let final = page.coverage.first { coverage = final }
        }
        guard let coverage else { throw CloudFailure.unavailable }
        return (operations, coverage)
    }
    func activate(_ row: String) async throws { _ = try await snapshot(row) }
    func close() async { await store.close(); try? FileManager.default.removeItem(at: base) }
    func apply(_ operations: [CloudOperation], row: String) async throws -> CloudImportReceipt {
        let adapter = try adapter(row), prepared = try await adapter.validateIncoming(operations, files: [])
        let receipt = try await adapter.applyPrepared(prepared, origin: .init(deviceId: deviceId, sequence: .init(1)))
        let verified = try await adapter.verify(receipt)
        guard verified.verified else { throw CloudFailure.checksumMismatch }
        return receipt
    }
}

extension DeckMemoryStore {
    func cloudFixtureSeedRows() throws {
        try db.transaction {
            try db.run("INSERT INTO board(id,kind,title,owner,doing,last_result,waiting,proof,updated) VALUES ('session-fixture','session','Prior work','hoot','Working','','','Proof',1000.125)")
            let snapshot = String(decoding: try JSONEncoder().encode(boardRow(id: "session-fixture")!), as: UTF8.self)
            for n in 1...2 { try db.run("INSERT INTO board_history(row_id,at,fields,snapshot) VALUES ('session-fixture',?,'doing',?)", [.real(Double(n)),.text(snapshot)]) }
            try db.run("INSERT INTO rewinds(id,owner,conversation,after_row,at,rows) VALUES (7,'hoot','fixture-chat',3,1000.125,1)")
            try db.run("UPDATE diary SET rewound=1000.125,rewind_id=7 WHERE external_id='four'")
            try db.run("INSERT INTO questions(owner,text,context,refs,asked,answer,answered) VALUES ('hoot','Keep this?','Prior context','[]',1000.125,'Yes',1000.25)")
            try setSetting("fixture preference", key: "fixture.preference", owner: .hoot)
        }
    }
    func cloudFixtureBackup() throws {
        let file = root.appendingPathComponent("archive/backups/memory-fixture.db")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try db.cloudBackup(to: file)
    }
    func cloudFixtureCount(_ table: String) throws -> Int { Int(try db.first("SELECT COUNT(*) FROM \(table)")?.int(0) ?? 0) }
    func cloudFixtureDiaryTexts() throws -> [String] { try db.rows("SELECT text FROM diary ORDER BY external_id").map { $0.text(0) } }
    func cloudFixtureVersions() throws -> [(String,String)] { try db.rows("SELECT resource_key,content_hash FROM cloud_memory_versions").map { ($0.text(0),$0.text(1)) } }
    func cloudFixtureQuestionId() throws -> Int64 { try db.first("SELECT id FROM questions LIMIT 1")!.int(0) }
    func cloudFixtureTrim() throws { try db.run("DELETE FROM board_history") }
    func cloudFixtureTempTriggers() throws -> [String] { try db.rows("SELECT name FROM sqlite_temp_master WHERE type='trigger' AND name LIKE 'cloud_memory_%'").map { $0.text(0) } }
    func cloudFixtureMainCloudObjects() throws -> [String] { try db.rows("SELECT name FROM main.sqlite_master WHERE name LIKE 'cloud%'").map { $0.text(0) } }
    func cloudFixtureJournalCount() throws -> Int { Int(try db.first("SELECT COUNT(*) FROM cloud_memory_journal")?.int(0) ?? 0) }
    func cloudFixtureEditDiary(_ external: String, text: String) throws { try db.run("UPDATE diary SET text=? WHERE external_id=?", [.text(text),.text(external)]) }
    func cloudFixtureDeleteControl(prefix: String) throws { try db.run("DELETE FROM cloud_memory_control WHERE key LIKE ?", [.text(prefix + "%")]) }
    /// What a relaunch forgets: the in-memory cache of cuts and their open readers.
    func cloudFixtureForgetSnapshots() { cloudMemorySnapshots = [:]; cloudCloseSnapshotReaders() }
    func cloudFixtureJournalRows(_ row: String) throws -> [String] {
        var last: Int64 = 0, keys: [String] = []
        while let resource = try cloudJournal(after: last, row: row) { keys.append(resource.key); last = resource.sequence }
        return keys
    }
}
