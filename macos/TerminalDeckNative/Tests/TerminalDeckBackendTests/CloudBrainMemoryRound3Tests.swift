import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review round 3 (R1-R4, M1b): the reconcile never sends a stale value, finishes on a quiet Mac, skips what it cannot
/// read, runs a full pass only when needed; the capture guard drops capture only for the side database.
@Suite("Cloud memory capture — round 3: reconcile and capture guard limits", .serialized)
struct CloudBrainMemoryRound3Tests {
    private static let subject = String(repeating: "f", count: 64)
    private func activation(_ f: CloudBrainMemoryFixture, _ store: DeckMemoryStore? = nil, rows: [String], retries: [Double] = []) throws -> BackendCloudBrainMemoryActivation {
        try BackendCloudBrainMemoryActivation(store: store ?? f.store, deviceId: f.deviceId, subjectHash: Self.subject, stateRoot: f.stateRoot,
                                              rows: rows, now: { 1000 }, retryDelays: retries)
    }
    private func reopen(_ f: CloudBrainMemoryFixture) async throws -> DeckMemoryStore {
        try await DeckMemoryStore.open(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
    }
    /// Waits (bounded) until `done` holds; the pumps run on their own tasks.
    private func eventually(_ done: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<600 { if try await done() { return true }; try await Task.sleep(nanoseconds: 10_000_000) }
        return false
    }

    @Test func aValueChangedBackWhileCaptureWasOffIsTheLastValueSent_R1() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try await f.store.cloudFixtureSetSetting("card.limit", "1000")
        let first = CaptureTestOutbox()
        let one = try activation(f, rows: ["I05"])
        try await one.start(outbox: first)
        // B is journaled while capture is on, but cannot be queued before the app quits.
        await first.setFailEnqueue(true)
        try await f.store.cloudFixtureSetSetting("card.limit", "2000")
        await f.store.close()
        // Next run, before activation (capture off): the value goes back to A.
        let reopened = try await reopen(f)
        try await reopened.cloudFixtureSetSetting("card.limit", "1000")
        let later = CaptureTestOutbox()
        let two = try activation(f, reopened, rows: ["I05"])
        try await two.start(outbox: later)
        // R1 is about ONE record: the last value sent for card.limit is the current one. Other settings (the Hoot seat's
        // title, written by the app itself) may legitimately be sent after it (run 8 sent seat.title last).
        let settled = try await eventually {
            let values = try await later.enqueuedParts().filter { $0.key.hasPrefix("row/settings/") }.compactMap { Data(base64Encoded: $0.data).map { String(decoding: $0, as: UTF8.self) } }
                .filter { $0.contains("\"card.limit\"") }
            return values.last?.contains("\"1000\"") == true && values.contains { $0.contains("\"2000\"") }
        }
        // When not settled, the failure names the exact state: journal, reconcile position and mode, pump problems and
        // cursors, capture state, the export head against the live row, and the settings values sent in order.
        var state = ""
        if !settled {
            let sent = try await later.enqueuedParts().filter { $0.key.hasPrefix("row/settings/") }.compactMap { Data(base64Encoded: $0.data).map { String(decoding: $0, as: UTF8.self) } }
            state = (try await reopened.cloudFixtureReconcileState(settingKey: "card.limit")) + "\nsent settings in order=" + sent.joined(separator: " | ")
        }
        #expect(settled, "\(state)") // the old queued 2000 went first; the current 1000 is the last value sent
        await two.stop(); await reopened.close(); try? FileManager.default.removeItem(at: f.base)
    }

    @Test func anInventoryThatIsNotEnabledLeavesNoJournalRowAndOthersStillSettle_run8() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let outbox = CaptureTestOutbox()
        let one = try activation(f, rows: ["I05"])
        try await one.start(outbox: outbox)
        // Files of I01/I04/I06 change while only I05 is enabled: nothing of them may enter the journal.
        try f.write("hoot/card.md", "# Card\nChanged while only settings travel.\n")
        try f.write("hoot/handoffs/h.md", "---\nid: h-fixture\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntitle: Handoff\n---\nChanged.\n")
        _ = try await f.store.reindex()
        try await f.store.cloudFixtureSetSetting("card.limit", "3000")
        let drained = try await eventually { try await f.store.cloudFixtureJournalInventories().isEmpty }
        #expect(drained)
        #expect(!(try await f.store.cloudFixtureJournalInventories().contains { ["I01", "I04", "I06"].contains($0) }))
        await one.stop(); await f.close()
    }
    @Test func aQuietMacFinishesItsPassWithoutAnyOtherMemoryChange_R2() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let drafts: [DeckMemoryDiaryDraft] = (0..<600).map { DeckMemoryDiaryDraft(stamp: .hoot, role: .user, text: "row \($0)", externalID: "quiet-\($0)") }
        _ = try await f.store.appendDiary(drafts)
        let one = try activation(f, rows: ["I02"])
        try await one.start(outbox: CaptureTestOutbox())
        await one.stop() // sign-out: a gap, so the next activation runs a full pass over 600+ unchanged rows
        try await f.store.cloudFixtureInsertDiaryRaw(text: "appended while off", external: "quiet-last")
        let later = CaptureTestOutbox()
        let two = try activation(f, rows: ["I02"])
        try await two.start(outbox: later)
        // No memory write happens from here on; only the reconcile's own tick can find the last row.
        let found = try await eventually {
            try await later.enqueuedParts().contains { Data(base64Encoded: $0.data).map { String(decoding: $0, as: UTF8.self).contains("appended while off") } ?? false }
        }
        #expect(found)
        #expect(try await eventually { !(try await f.store.cloudReconcilePending()) })
        await two.stop(); await f.close()
    }

    @Test func anUnreadableRowIsSkippedAndNamedAndTheRestIsStillChecked_R3() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let broken = try await f.store.cloudFixtureQuestionId()
        // Both rows exist before capture, so nothing waits in the journal for this row (R1 would hold the pass).
        let later = try await f.store.cloudFixtureInsertQuestion("A later question")
        try await f.capture()
        // An origin record that no longer matches its row: rebuilding this one row for export fails.
        try await f.store.cloudFixturePlantBrokenOrigin(table: "questions", id: broken)
        try await f.store.cloudStartReconcile(full: true)
        while try await f.store.cloudReconcileRows(limit: 1000) > 0 {}
        #expect(try await f.store.cloudReconcileSkipped("I05") == 1)
        let inventory = try await f.adapter("I05").sourceInventory()[0]
        #expect(inventory.blockedReasons.contains { $0.contains("could not be read for Cloud") })
        #expect(try await f.store.cloudFixtureJournalCount(inventory: "I05", containing: "A later question") == 1)
        _ = later
        await f.close()
    }

    @Test func aCleanLaunchRunsNoFullPassAndAnUncleanOneDoes_R4() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let one = try activation(f, rows: ["I02"])
        try await one.start(outbox: CaptureTestOutbox())
        await f.store.close() // clean quit while capture is on
        let reopened = try await reopen(f)
        let two = try activation(f, reopened, rows: ["I02"])
        try await two.start(outbox: CaptureTestOutbox())
        #expect(try await reopened.cloudFixtureControl("reconcileMode") == "tail")
        await two.stop(); await reopened.close()
        // An unclean end alone: no clean-close record (the sign-out's gap marker is removed so it cannot be the reason).
        try? FileManager.default.removeItem(at: f.stateRoot.appendingPathComponent("capture-gap"))
        let again = try await reopen(f)
        try await again.cloudResumeCapture(stateRoot: f.stateRoot)
        try await again.cloudFixtureDeleteControl(prefix: "cleanClose")
        let three = try activation(f, again, rows: ["I02"])
        try await three.start(outbox: CaptureTestOutbox())
        #expect(try await again.cloudFixtureControl("reconcileMode") == "full")
        await three.stop(); await again.close(); try? FileManager.default.removeItem(at: f.base)
    }

    @Test func anUnreadableSideFileIsDetachedAndTheMemoryWriteSucceeds_M1b() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I02")
        // Overwrite the side database's first page in place: BEGIN IMMEDIATE can no longer read it.
        let side = try FileHandle(forWritingTo: f.stateRoot.appendingPathComponent("memory-cloud.db"))
        try side.seek(toOffset: 0); try side.write(contentsOf: Data(repeating: 0x5A, count: 4096)); try side.close()
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "written anyway", externalID: "m1b-side"))
        #expect(try await f.store.cloudFixtureDiaryTexts().contains("written anyway"))
        #expect(await f.store.cloudCaptureLost)
        #expect(!(try await f.store.cloudAttached()))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        await f.close()
    }

    @Test func memorysOwnConstraintErrorLeavesCaptureOnWithNoGap_M1b() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I02")
        await #expect(throws: (any Error).self) { try await f.store.cloudFixtureInsertDiaryRaw(text: "duplicate", external: "one") }
        #expect(await f.store.cloudMemoryEnabled)
        #expect(!(await f.store.cloudCaptureLost))
        #expect(try await f.store.cloudFixtureCaptureLoss() == nil)
        #expect(!(try await f.store.cloudFixtureTempTriggers()).isEmpty)
        #expect(try await f.store.cloudAttached())
        #expect(!FileManager.default.fileExists(atPath: f.stateRoot.appendingPathComponent("capture-gap").path))
        await f.close()
    }

    @Test func fiveFailedActivationAttemptsLeaveCaptureOffWithAGap_M1b() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let outbox = CaptureTestOutbox(); await outbox.setFailEveryBootstrap(true)
        let one = try activation(f, rows: ["I02"], retries: [0, 0, 0, 0, 0])
        await #expect(throws: CloudFailure.unavailable) { try await one.start(outbox: outbox) }
        #expect(await outbox.cuts.count == 6)
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.stateRoot.appendingPathComponent("capture-gap").path))
        #expect(await one.pumpCount == 0)
        await f.close()
    }
}

extension DeckMemoryStore {
    func cloudFixtureSetSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings(owner,key,value,updated) VALUES ('',?,?,1000.25) ON CONFLICT(owner,key) DO UPDATE SET value=excluded.value,updated=excluded.updated", [.text(key), .text(value)])
    }
    func cloudFixtureInsertDiaryRaw(text: String, external: String) throws {
        try db.run("INSERT INTO diary(owner,role,text,external_id,at,saved) VALUES ('hoot','user',?,?,1000.25,1000.25)", [.text(text), .text(external)])
    }
    func cloudFixtureInsertQuestion(_ text: String) throws -> Int64 {
        try db.run("INSERT INTO questions(owner,text,asked) VALUES ('hoot',?,1000.25)", [.text(text)])
    }
    func cloudFixturePlantBrokenOrigin(table: String, id: Int64) throws {
        let nativeKey = "[{\"type\":\"integer\",\"value\":\"" + String(id) + "\"}]"
        try db.run("INSERT OR REPLACE INTO cloud_memory_origins(table_name,native_key,store_id,resource_key,original_keys,version) VALUES (?,?,?,?,CAST('[]' AS BLOB),NULL)",
                   [.text(table), .text(nativeKey), .text("00000000-0000-4000-8000-000000000001"), .text("row/" + table + "/broken")])
    }
    func cloudFixtureJournalCount(inventory: String, containing text: String) throws -> Int {
        try db.rows("SELECT body FROM cloud_memory_journal WHERE inventory=?", [.text(inventory)]).filter {
            $0.data(0).map { String(decoding: $0, as: UTF8.self).contains(text) } ?? false
        }.count
    }
    func cloudFixtureCaptureLoss() -> String? { db.captureLost }
    /// Diagnostics for the R1 test: every fact the "settled" condition depends on.
    func cloudFixtureJournalInventories() throws -> [String] {
        try db.rows("SELECT DISTINCT inventory FROM cloud_memory_journal").map { $0.text(0) }
    }
    func cloudFixtureReconcileState(settingKey: String) throws -> String {
        var out: [String] = []
        out.append("journal(inventory,resource_key,seq)=" + (try db.rows("SELECT inventory,resource_key,seq FROM cloud_memory_journal ORDER BY seq")
            .map { $0.text(0) + "," + $0.text(1) + "," + String($0.int(2)) }.joined(separator: ";")))
        out.append("control=" + (try db.rows("SELECT key,value FROM cloud_memory_control WHERE key IN ('rowsReconcile','reconcileMode','tailFirst','captureProblem','cleanClose','filesDirty') OR key LIKE 'pumpProblem:%' OR key LIKE 'sourceCursor:%' OR key LIKE 'reconcileSkipped:%' ORDER BY key")
            .map { $0.text(0) + "=" + $0.text(1) }.joined(separator: ";")))
        out.append("capture enabled=\(cloudMemoryEnabled) lost=\(cloudCaptureLost) guardLoss=\(db.captureLost ?? "nil") triggers=" + String(try db.rows("SELECT name FROM sqlite_temp_master WHERE type='trigger' AND name LIKE 'cloud_memory_%'").count))
        let t = try DeckMemoryCloudSchema.table("settings"), storeId = try cloudStoreId()
        if let r = try db.first("SELECT \(t.columns.joined(separator: ",")) FROM main.settings WHERE owner='' AND key=?", [.text(settingKey)]) {
            let live = try cloudLogicalRow(t, values: r.values, database: db, storeId: storeId, sequence: 0, row: t.row)
            let headKey = (live.originStoreId ?? storeId) + ":" + live.key
            let head = try db.first("SELECT hash,version FROM cloud_memory_export_heads WHERE resource_key=?", [.text(headKey)])
            out.append("live hash=" + live.hash + " head hash=" + (head?.text(0) ?? "none") + " head version=" + (head?.text(1) ?? "none") + " key=" + headKey)
        } else { out.append("live row missing") }
        return out.joined(separator: "\n")
    }
}
