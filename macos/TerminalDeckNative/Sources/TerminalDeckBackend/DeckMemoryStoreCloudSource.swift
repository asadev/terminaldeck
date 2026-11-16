import Foundation
import TerminalDeckNativeCore

struct DeckMemoryCloudResource: Sendable {
    let originStoreId: String?
    let baseVersion: String?
    let physicalRow: Data?
    let projectionPath: String?
    let physicalHash: String?
    init(sequence: Int64, row: String, key: String, hash: String, bytes: Int64, data: Data?, file: URL?, originStoreId: String? = nil, baseVersion: String? = nil, physicalRow: Data? = nil, projectionPath: String? = nil, physicalHash: String? = nil) {
        self.sequence = sequence; self.row = row; self.key = key; self.hash = hash; self.bytes = bytes; self.data = data; self.file = file
        self.originStoreId = originStoreId; self.baseVersion = baseVersion; self.physicalRow = physicalRow; self.projectionPath = projectionPath; self.physicalHash = physicalHash
    }
    let sequence: Int64
    let row: String
    let key: String
    let hash: String
    let bytes: Int64
    let data: Data?
    let file: URL?
}
/// A cut: database copies plus the file list; file bytes are copied lazily, once, off the memory actor.
struct DeckMemoryCloudSnapshot: Codable, Sendable {
    let root: URL
    let storeId: String
    let watermark: Int64
    let files: [String]
    /// Always empty from this release on: local database backups never travel (Decker, finding 8). Kept for older headers.
    let backups: [String]
    /// `prior-roots/<id>` prefix → that previous memory folder, so its archived files can be copied later.
    let sources: [String: String]?
    /// Named intentional exclusions per inventory row, fixed at the cut so every replay of its pages is identical.
    let exclusions: [String: [String]]?
}
/// One walk of a memory folder: the files that travel and what was deliberately left out (M5, M6).
struct DeckMemoryCloudFileScan: Sendable {
    var paths: [String] = []
    var hidden = 0
    var links = 0
    var appHelp = 0
    var exclusions: [String] { DeckMemoryCloudSchema.fileExclusions(hidden: hidden, links: links, appHelp: appHelp) }
}

extension DeckMemoryStore {
    /// The cut only, on the actor: an online SQLite copy of main and of the account database, the journal watermark and
    /// the file list. No file is copied or hashed here (finding 9). Capture must already be on (activation does that first).
    /// A destination without a completed header is a failed earlier attempt and is replaced, so a retry is clean (finding 10).
    func cloudBeginSnapshot(id: String, destination: URL, availableSpace: (@Sendable () throws -> Int64)? = nil) throws -> DeckMemoryCloudSnapshot {
        guard UUID(uuidString: id) != nil, !closed, !destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw CloudFailure.invalidRequest }
        guard cloudMemoryEnabled, try cloudAttached() else { throw CloudFailure.unavailable }
        if let saved = cloudMemorySnapshots[id] { return saved }
        let fm = FileManager.default
        let metadata = destination.appendingPathComponent(".cloud-snapshot.json"), hashKey = "snapshotHash:" + id
        if fm.fileExists(atPath: destination.path) {
            if fm.fileExists(atPath: metadata.path) {
                let metadataBytes = try Data(contentsOf: metadata)
                let saved = try JSONDecoder().decode(DeckMemoryCloudSnapshot.self, from: metadataBytes)
                // Compare paths: a URL made for an existing folder gains a trailing slash, the one saved at the cut did not.
                guard saved.root.standardizedFileURL.path == destination.standardizedFileURL.path, UUID(uuidString: saved.storeId) != nil, saved.watermark >= 0 else { throw CloudFailure.invalidRequest }
                for path in saved.files + ["memory.db"] { _ = try DeckMemoryCloudSchema.safePath(path, root: destination) }
                if let recorded = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(hashKey)])?.string(0) {
                    guard recorded == DeckMemoryFiles.hash(metadataBytes) else { throw CloudFailure.checksumMismatch }
                } else {
                    // M8: killed between moving the finished folder into place and recording its hash. The header is
                    // written last inside the staging folder and the move is atomic, so a header here means a complete
                    // cut; only this account's own snapshots folder is trusted this way.
                    guard let state = cloudStateRoot, destination.standardizedFileURL.path.hasPrefix(state.standardizedFileURL.path + "/snapshots/") else { throw CloudFailure.idReused }
                    try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(hashKey),.text(DeckMemoryFiles.hash(metadataBytes))])
                }
                guard saved.storeId == (try cloudStoreId()) else { throw CloudFailure.idReused }
                cloudMemorySnapshots[id] = saved
                return saved
            }
            // Only a folder this account made under its own snapshots folder is ever removed.
            guard let state = cloudStateRoot, destination.standardizedFileURL.path.hasPrefix(state.standardizedFileURL.path + "/snapshots/") else { throw CloudFailure.idReused }
            try fm.removeItem(at: destination)
        }
        let previousRoots = try cloudPreviousRoots()
        var sources: [String: String] = [:], priorFiles: [String] = []
        var scan = try cloudScanSourceFiles()
        for previous in previousRoots {
            let prefix = "prior-roots/" + BackendCloudBrainMemoryHash.uuid(previous.path)
            sources[prefix] = previous.path
            // Archived notes/cards/topics of an earlier memory folder travel as files; its databases stay local.
            let prior = try cloudScanSourceFiles(under: previous)
            scan.hidden += prior.hidden; scan.links += prior.links; scan.appHelp += prior.appHelp
            for relative in prior.paths { priorFiles.append(prefix + "/" + relative) }
        }
        let localMarks = Set(try CloudDeleteState(memory: db).marks().map(\.place))
        let paths = scan.paths.filter { !localMarks.contains($0) }
        let settingKeys = try db.rows("SELECT DISTINCT key FROM main.settings").map { $0.text(0) }
        var exclusions: [String: [String]] = [:]
        if !scan.exclusions.isEmpty { exclusions["I01"] = scan.exclusions }
        let unknownSettings = DeckMemoryCloudSchema.unknownSettingNotes(settingKeys)
        if !unknownSettings.isEmpty { exclusions["I05"] = unknownSettings }
        if let note = DeckMemoryCloudSchema.intentionalExclusions["I06"] { exclusions["I06"] = [note] }
        try cloudSaveFileExclusions(scan)
        var required: Int64 = 64 * 1024 * 1024
        required += (try fm.attributesOfItem(atPath: root.appendingPathComponent("memory.db").path)[.size] as? NSNumber)?.int64Value ?? 0
        for path in paths { required += (try? fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size] as? NSNumber)?.int64Value ?? 0 }
        let free: Int64
        if let availableSpace { free = try availableSpace() }
        else {
            var volumeRoot = destination.deletingLastPathComponent()
            while !fm.fileExists(atPath: volumeRoot.path), volumeRoot.path != "/" { volumeRoot.deleteLastPathComponent() }
            let volume = try volumeRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,.volumeAvailableCapacityKey])
            free = volume.volumeAvailableCapacityForImportantUsage ?? Int64(volume.volumeAvailableCapacity ?? 0)
        }
        guard free > required else { throw CloudFailure.unavailable }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".preparing-" + id)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // The cut: both copies and the watermark are taken without an await, so no memory write interleaves.
            try db.cloudBackup(to: staging.appendingPathComponent("memory.db"))
            try db.cloudBackup(to: staging.appendingPathComponent("memory-cloud.db"), schema: "cloud")
            // File labels are derived data too. A marked note's title/snippet must not escape through a database cut
            // after its local-only text was edited. Prune only the disposable copy, never the real memory database.
            if !localMarks.isEmpty {
                let copy = try DeckMemoryDatabase(path: staging.appendingPathComponent("memory.db").path)
                defer { copy.close() }
                for table in Self.cloudFileLabelTables {
                    guard try copy.rows("PRAGMA table_info(\(table))").contains(where: { $0.text(1) == "path" }) else { continue }
                    for path in localMarks { try copy.run("DELETE FROM \(table) WHERE path=?", [.text(path)]) }
                }
            }
            let storeId = try cloudStoreId()
            let watermark = try db.first("SELECT COALESCE(MAX(seq),0) FROM cloud_memory_journal")?.int(0) ?? 0
            let snapshot = DeckMemoryCloudSnapshot(root: destination, storeId: storeId, watermark: watermark, files: paths + priorFiles, backups: [], sources: sources, exclusions: exclusions)
            let metadataBytes = try CloudWire.canonical(snapshot)
            try metadataBytes.write(to: staging.appendingPathComponent(".cloud-snapshot.json"), options: .atomic)
            try BackendCloudBrainMemoryHash.synchronize(staging.appendingPathComponent(".cloud-snapshot.json"))
            try fm.moveItem(at: staging, to: destination)
            try BackendCloudBrainMemoryHash.synchronizeDirectory(destination.deletingLastPathComponent())
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(hashKey),.text(DeckMemoryFiles.hash(metadataBytes))])
            cloudMemorySnapshots[id] = snapshot
            return snapshot
        } catch {
            try? fm.removeItem(at: staging)
            if fm.fileExists(atPath: destination.path), (try? db.first("SELECT 1 FROM cloud_memory_control WHERE key=?", [.text(hashKey)])) == nil {
                try? fm.removeItem(at: destination)
            }
            throw error
        }
    }
    func cloudRootURL() -> URL { root }
    func cloudStoreId() throws -> String {
        if let value = try db.first("SELECT value FROM cloud_memory_control WHERE key='storeId'")?.string(0) { return value }
        let value = UUID().uuidString.lowercased()
        try db.run("INSERT INTO cloud_memory_control(key,value) VALUES ('storeId',?)", [.text(value)])
        return value
    }
    func cloudPreviousRoots() throws -> [URL] {
        guard let dataRoot else { return [] }
        let pointer = DeckMemoryPaths.pointer(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: pointer.path) else { return [] }
        let saved = try JSONDecoder().decode(DeckMemoryPaths.Pointer.self, from: Data(contentsOf: pointer))
        var roots: [URL] = []
        for path in saved.previous {
            guard path.hasPrefix("/") else { throw CloudFailure.unsafeConfiguration }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if url.path != root.resolvingSymlinksInPath().path, !roots.contains(url) { roots.append(url) }
        }
        return roots
    }
    /// Every regular file under the memory root that travels (finding 20): everything except memory.db*, Cloud's own
    /// `.cloud*` leftovers and local database backups. `prefixes` limits the walk to those folders or files.
    func cloudSourceFiles(under sourceRoot: URL? = nil, prefixes: [String]? = nil) throws -> [String] {
        try cloudScanSourceFiles(under: sourceRoot, prefixes: prefixes).paths
    }
    /// M5/M6: hidden files and folders (any name starting with "."), links (never followed) and the app's own help files
    /// at the memory root never travel and never abort a walk; they are counted so coverage can name them.
    func cloudScanSourceFiles(under sourceRoot: URL? = nil, prefixes: [String]? = nil) throws -> DeckMemoryCloudFileScan {
        let base = (sourceRoot ?? root).standardizedFileURL
        let fm = FileManager.default
        var scan = DeckMemoryCloudFileScan(), seen = Set<String>()
        func isAppHelp(_ relative: String, _ file: URL) -> Bool {
            guard !relative.contains("/"), DeckMemoryCloudSchema.appHelpFiles.contains(relative) else { return false }
            return DeckMemoryFiles.read(file)?.contains(DeckMemoryFiles.generatedMarker) == true
        }
        for start in prefixes ?? [""] {
            let startParts = start.split(separator: "/")
            if startParts.contains(where: { $0.hasPrefix(".") }) {
                if !startParts.contains(where: { $0.hasPrefix(".cloud") }) { scan.hidden += 1 }
                continue
            }
            let folder: URL
            do { folder = start.isEmpty ? base : try DeckMemoryCloudSchema.safePath(start, root: base) }
            catch CloudFailure.unsafeConfiguration { scan.links += 1; continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if isAppHelp(start, folder) { scan.appHelp += 1 }
                else if DeckMemoryCloudSchema.fileRow(start) != nil, seen.insert(start).inserted { scan.paths.append(start) }
                continue
            }
            var failure: Error?
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey], options: [], errorHandler: { _, error in failure = error; return false }) else { throw CloudFailure.unavailable }
            for case let file as URL in e {
                let path = String(file.standardizedFileURL.path.dropFirst(base.path.count + 1))
                let components = path.split(separator: "/")
                if components.contains(where: { $0.hasPrefix(".cloud") }) { e.skipDescendants(); continue }
                if components.contains(where: { $0.hasPrefix(".") }) { scan.hidden += 1; e.skipDescendants(); continue }
                let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey])
                if info.isSymbolicLink == true { scan.links += 1; continue }
                if info.isDirectory == true { continue }
                guard info.isRegularFile == true else { continue }
                if isAppHelp(path, file) { scan.appHelp += 1; continue }
                guard DeckMemoryCloudSchema.fileRow(path) != nil else { continue }
                if seen.insert(path).inserted { scan.paths.append(path) }
            }
            if let failure { throw failure }
        }
        scan.paths.sort()
        return scan
    }
    /// The named file exclusions of the last full walk, for the live inventory (I01).
    func cloudSaveFileExclusions(_ scan: DeckMemoryCloudFileScan) throws {
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('fileExclusions',?)",
                   [.text(String(decoding: try CloudWire.canonical(scan.exclusions), as: UTF8.self))])
    }
    func cloudSavedFileExclusions() throws -> [String] {
        guard let text = try db.first("SELECT value FROM cloud_memory_control WHERE key='fileExclusions'")?.string(0) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }
    func cloudHashFile(_ file: URL) throws -> String { try BackendCloudBrainMemoryHash.file(file) }
    /// Assembled incoming/exported raw copies for the import side, in the account folder (not `.cloud-local` in memory).
    func cloudIncomingFolder() throws -> URL {
        guard let state = cloudStateRoot else { throw CloudFailure.unavailable }
        return state.appendingPathComponent("incoming", isDirectory: true)
    }
    /// Retained byte copies live in the account's own folder, never inside the memory folder.
    func cloudVersionsFolder() throws -> URL {
        guard let state = cloudStateRoot else { throw CloudFailure.unavailable }
        return state.appendingPathComponent("versions", isDirectory: true)
    }

    /// Captures changed files under `paths` (folders or files). nil means "unknown": the folder is marked dirty and the
    /// bounded reconcile looks later, never a whole-folder scan inside a save (finding 12).
    func cloudCaptureChangedFiles(force: Bool = false, paths: [String]? = nil) throws {
        guard cloudMemoryEnabled else { return }
        guard try db.first("SELECT value FROM cloud_memory_control WHERE key='importing'")?.text(0) != "1" else { return }
        guard let paths else { try cloudMarkFilesDirty(); return }
        cloudFilesExamined = 0
        let scan = try cloudScanSourceFiles(prefixes: paths)
        // Captured first, then the removals: a renamed file's new place is known when its old place's removal is
        // written, so the removal says where it moved (lane memory-one-rule).
        for path in scan.paths { try cloudCaptureFile(path, force: force) }
        try cloudForgetRemovedFiles(prefixes: paths)
        // M5: a link met by a save is skipped, never followed; a full pass then names it in coverage.
        if scan.links > 0 {
            let named = try cloudSavedFileExclusions().contains { $0.hasPrefix("Linked files") }
            if !named { try cloudMarkFilesDirty() }
        }
        try db.run("DELETE FROM cloud_memory_control WHERE key='captureProblem' AND value='capture_failed'")
    }
    func cloudCaptureAfterSave(_ area: DeckMemoryChange.Area, _ owner: DeckMemoryOwner?, _ ref: String?) {
        do {
            // M9: outside edits arrive through the folder watcher, which already captured the named paths (or marked a
            // real rescan); the index and folder notices that follow never send the whole folder round again.
            if area == .index || area == .folder || cloudCaptureFromWatcher { return }
            // Decision 1: the app's own archive/restore is recorded as a move before the capture looks at the old place.
            try? cloudRecordAppMoves(area, ref)
            if area == .templates, let ref, DeckMemoryCategory(rawValue: ref) != nil { try cloudCaptureChangedFiles(paths: ["templates/" + ref]) }
            else if let owner { try cloudCaptureChangedFiles(paths: [owner.folder]) }
            else if let ref, ref.contains("/"), (try? DeckMemoryCloudSchema.safePath(ref, root: root)) != nil { try cloudCaptureChangedFiles(paths: [ref]) }
            else { try cloudMarkFilesDirty() }
        } catch { try? db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('captureProblem','capture_failed')") }
    }
    func cloudMarkFilesDirty() throws {
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('filesDirty','1')")
        try db.run("DELETE FROM cloud_memory_control WHERE key='filesCursor'")
        cloudReconcileList = nil
    }
    /// One bounded step of the file reconcile: at most `limit` files are looked at per call, resuming from a saved cursor.
    /// Returns how many were looked at; 0 means nothing is dirty any more. Called by the pumps and by activation catch-up.
    func cloudReconcileFiles(limit: Int = 64) throws -> Int {
        guard cloudMemoryEnabled, try db.first("SELECT value FROM cloud_memory_control WHERE key='filesDirty'")?.text(0) == "1" else { cloudReconcileList = nil; return 0 }
        let after = try db.first("SELECT value FROM cloud_memory_control WHERE key='filesCursor'")?.string(0) ?? ""
        // M9: listed once per pass (once more after a relaunch), then consumed from the saved position.
        if cloudReconcileList == nil {
            let scan = try cloudScanSourceFiles()
            try cloudSaveFileExclusions(scan)
            cloudReconcileList = scan.paths
        }
        let all = cloudReconcileList ?? []
        var low = 0, high = all.count
        while low < high { let mid = (low + high) / 2; if all[mid] > after { high = mid } else { low = mid + 1 } }
        let batch = Array(all[low..<min(all.count, low + max(1, limit))])
        cloudFilesExamined = 0
        for path in batch where FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { try cloudCaptureFile(path, force: false) }
        if low + batch.count >= all.count {
            // Missing files become local marks unless a move, intent or affirmative witness says otherwise.
            try cloudForgetRemovedFiles(prefixes: nil)
            try db.run("DELETE FROM cloud_memory_control WHERE key IN ('filesDirty','filesCursor')")
            cloudReconcileList = nil
        } else if let last = batch.last {
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('filesCursor',?)", [.text(last)])
        }
        return batch.count
    }
    /// Last-seen rows are observation, never authority to delete elsewhere. Two missing looks let editors finish
    /// an atomic rewrite; only a durable intent, a move the app recorded or an affirmative AI witness may travel.
    /// Decision 3: one file at a time; a file whose delete cannot be finished never stops the pass for the others.
    func cloudForgetRemovedFiles(prefixes: [String]?) throws {
        guard cloudMemoryEnabled, try cloudAttached(), cloudMemoryRootAvailable(), try cloudMigrateDeleteRule() else { return }
        let fm = FileManager.default, at = cloudNowMs()
        let allSeenKey = "deleteRule:allSeenAt"
        // Decision 9: the last full look (every captured file that was there then was positively seen at that time).
        let previousFullLook = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(allSeenKey)])?.string(0).flatMap(Int64.init)
        var recheckAt: Int64?, failed = 0
        for row in try db.rows("SELECT path,hash FROM cloud_memory_files") {
            let path = row.text(0), hash = row.string(1)
            if let prefixes, !prefixes.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { continue }
            guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root) else { continue }
            if fm.fileExists(atPath: file.path) {
                try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("deleteRule:gone:" + path)])
                continue
            }
            do {
                if let deadline = try cloudForgetRemovedFile(path, hash: hash, file: file, at: at, previousFullLook: previousFullLook) {
                    recheckAt = min(recheckAt ?? Int64.max, deadline)
                }
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            CloudSyncDiagnostics.shared.info("memory: \(failed) missing " + (failed == 1 ? "file" : "files") + " could not be recorded on this Mac yet; their Cloud copies were kept and the other files went on.")
        }
        if prefixes == nil { try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(allSeenKey), .text(String(at))]) }
        if let recheckAt { try cloudScheduleMemoryGoneLook(at: recheckAt) }
    }
    /// One gone file. Returns the time of its second look when it still waits for one.
    private func cloudForgetRemovedFile(_ path: String, hash: String?, file: URL, at: Int64, previousFullLook: Int64?) throws -> Int64? {
        let state = try CloudDeleteState(memory: db)
        if try cloudConvertMarked(path) || state.mark(at: path) != nil { return nil }
        if try state.intent(at: path) != nil { try cloudFinishMemoryIntent(path); return nil }
        let goneKey = "deleteRule:gone:" + path, seenKey = "deleteRule:seen:" + path
        // Decision 1: only a move the app made and recorded travels as a move. Anything else is a hand absence.
        if try cloudRecordedMove(from: path) != nil || cloudArchivedByApp(path) {
            let origin = try db.first("SELECT store_id,resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(path)])
            let store = try origin?.text(0) ?? cloudStoreId(), key = origin?.text(1) ?? "file/" + path
            let lastBytes = try cloudLastBytes(path: path, store: store, key: key, lastHash: hash)
            if try cloudMovedTo(path, lastBytes: lastBytes) != nil {
                let result = try cloudJournalRemoval(path: path, lastHash: hash, onlyMove: true, knownBytes: lastBytes)
                if result == .sent || result == .nothing {
                    try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)])
                    try cloudForgetRecordedMove(path)
                }
                return nil
            }
        }
        let first = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(goneKey)])?.string(0).flatMap(Int64.init)
        guard let first, at >= first, at - first >= 3_000 else {
            if first == nil || at < (first ?? 0) {
                try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(goneKey), .text(String(at))])
                // Decision 9: the last moment this Mac positively saw the file: its last capture, or the last full look
                // (which found it there, or it would have been noticed gone then).
                let seen = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(seenKey)])?.string(0).flatMap(Int64.init)
                if let best = [seen, previousFullLook].compactMap({ $0 }).filter({ $0 <= at }).max(), best != seen {
                    try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(seenKey), .text(String(best))])
                }
            }
            return (first ?? at) + 3_000
        }
        let witnessKey = "deleteRule:witness:" + path
        let started = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(witnessKey)])?.string(0).flatMap(Int64.init)
        if let started, at >= started, at - started < 30_000 { return nil }
        let seen = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(seenKey)])?.string(0).flatMap(Int64.init)
        let last = min(seen ?? (first - 3_000), first)
        let offset = cloudNowMs() - Int64(Date().timeIntervalSince1970 * 1000)
        // Decision 9: the app was not running during part of that window: nobody watched, so it counts as by hand,
        // without asking.
        if last < cloudRunStartedAtMs() {
            try cloudResolveMemoryGone(path: path, lastHash: hash, lastSeen: Self.cloudLocalDate(last, offset: offset), goneAt: Self.cloudLocalDate(first, offset: offset), answer: .cannotKnow)
            return nil
        }
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(witnessKey), .text(String(at))])
        // The witness works on this Mac's own clock (command times); the window is the narrowest honest one.
        let lastSeen = Self.cloudLocalDate(last, offset: offset), goneAt = Self.cloudLocalDate(first, offset: offset)
        let account = cloudStateRoot?.standardizedFileURL.path
        let witness = cloudDeleteWitness()
        // Decision 7: the answer is handled by ONE store method that waits its turn on the store.
        Task { [weak self] in
            let answer = await witness.who(removed: file, lastSeen: lastSeen, seenGoneAt: goneAt)
            await self?.cloudMemoryWitnessAnswered(path: path, lastHash: hash, lastSeen: lastSeen, goneAt: goneAt, answer: answer, account: account)
        }
        return nil
    }
    static func cloudLocalDate(_ serviceMs: Int64, offset: Int64) -> Date { Date(timeIntervalSince1970: Double(serviceMs - offset) / 1000) }
    /// An archive the app itself made (its archived stamp and `origin_path` on a note or hand-off with this place).
    private func cloudArchivedByApp(_ path: String) throws -> Bool {
        for table in ["notes", "handoffs"] where try db.first("SELECT 1 FROM \(table) WHERE origin_path=? AND archived IS NOT NULL AND missing=0 AND path<>? LIMIT 1", [.text(path), .text(path)]) != nil {
            return true
        }
        return false
    }
    /// The witness answered (decision 7: on the store, in turn). Every observation is checked again inside.
    func cloudMemoryWitnessAnswered(path: String, lastHash: String?, lastSeen: Date, goneAt: Date, answer: CloudDeleteWitnessAnswer, account: String?) {
        guard cloudStateRoot?.standardizedFileURL.path == account, !closed else { return }
        let witnessKey = "deleteRule:witness:" + path
        do {
            try cloudResolveMemoryGone(path: path, lastHash: lastHash, lastSeen: lastSeen, goneAt: goneAt, answer: answer)
            try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(witnessKey)])
            hub.post(.init(area: .index, at: now()))
        } catch {
            CloudSyncDiagnostics.shared.info("A missing memory file could not be recorded on this Mac; its Cloud copy was kept.")
            try? db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(witnessKey)])
        }
    }
    /// One deadline for a whole batch, rather than a timer or task per missing file. It wakes an otherwise idle pump.
    private func cloudScheduleMemoryGoneLook(at deadline: Int64) throws {
        let key = "deleteRule:recheckAt"
        if let scheduled = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0).flatMap(Int64.init), scheduled <= deadline { return }
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(key), .text(String(deadline))])
        let account = cloudStateRoot?.standardizedFileURL.path
        let delay = max(1, deadline - cloudNowMs())
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            await self?.cloudMemoryGoneDeadline(deadline, account: account)
        }
    }
    /// The second look's deadline (decision 7: one store method, awaited).
    func cloudMemoryGoneDeadline(_ deadline: Int64, account: String?) {
        let key = "deleteRule:recheckAt"
        guard !closed, cloudMemoryEnabled, cloudStateRoot?.standardizedFileURL.path == account else { return }
        do {
            guard try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0) == String(deadline) else { return }
            try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(key)])
            try cloudForgetRemovedFiles(prefixes: nil)
            hub.post(.init(area: .index, at: now()))
        } catch {
            CloudSyncDiagnostics.shared.info("A missing memory file will be checked again on this Mac; its Cloud copy was kept.")
        }
    }
    /// The witness this store asks (the shared one; a test passes its own, since the shared one is installed once).
    func cloudDeleteWitness() -> CloudDeleteWitnessSlot { DeckMemoryDeleteRuleHooks.shared.slot(for: ObjectIdentifier(self)) ?? .shared }
    /// Tests only: this store's own witness and, optionally, when this run of the app started (service ms).
    func cloudDeleteUseWitness(_ slot: CloudDeleteWitnessSlot, runStartedAt: Int64? = nil) {
        DeckMemoryDeleteRuleHooks.shared.set(slot: slot, runStartedAt: runStartedAt, for: ObjectIdentifier(self))
    }
    /// When this run of the app started, on the service clock (decision 9). Before it nobody watched the folder.
    func cloudRunStartedAtMs() -> Int64 {
        if let given = DeckMemoryDeleteRuleHooks.shared.runStartedAt(for: ObjectIdentifier(self)) { return given }
        let offset = cloudNowMs() - Int64(Date().timeIntervalSince1970 * 1000)
        return Int64(DeckMemoryDeleteRuleHooks.processStartedAt.timeIntervalSince1970 * 1000) + offset
    }
    /// The app itself moved a note or hand-off (archive, restore): its old place's removal may travel as a move
    /// (decision 1). Called for the app's own saves only, never for folder-watcher events.
    func cloudRecordAppMoves(_ area: DeckMemoryChange.Area, _ ref: String?) throws {
        guard let ref, !ref.isEmpty else { return }
        let table: String, id: String
        if area == .notes { table = "notes"; id = ref }
        else if area == .topics, ref.hasPrefix("handoff:") { table = "handoffs"; id = String(ref.dropFirst("handoff:".count)) }
        else { return }
        guard let row = try db.first("SELECT path,archived,origin_path FROM \(table) WHERE id=? AND missing=0", [.text(id)]) else { return }
        let now = row.text(0), fm = FileManager.default
        func gone(_ path: String) -> Bool { (try? DeckMemoryCloudSchema.safePath(path, root: root)).map { !fm.fileExists(atPath: $0.path) } ?? false }
        if !row.isNull(1) {
            // Archived: its place before the archive.
            if let origin = row.string(2), origin != now, gone(origin) { try cloudRecordMemoryMove(from: origin, to: now) }
            return
        }
        // Restored: its archived place (archive/<same folder>/...), when that place is gone and held this very note.
        let folder = "archive/" + (now as NSString).deletingLastPathComponent + "/"
        let own = try cloudStoreId()
        for captured in try db.rows("SELECT path,hash FROM cloud_memory_files WHERE substr(path,1,?)=?", [.int(Int64(folder.count)), .text(folder)]) {
            let archived = captured.text(0)
            guard gone(archived) else { continue }
            let origin = try db.first("SELECT store_id,resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(archived)])
            guard let bytes = try cloudLastBytes(path: archived, store: origin?.text(0) ?? own, key: origin?.text(1) ?? "file/" + archived, lastHash: captured.string(1)),
                  let text = String(data: bytes, encoding: .utf8), DeckMemoryFile(text: text).value("id") == id else { continue }
            try cloudRecordMemoryMove(from: archived, to: now)
        }
    }
    /// An immutable byte copy is retained (in the account folder) before the change is journaled. Nothing is removed after upload
    /// except by the journal prune once the operation is durably queued.
    func cloudCaptureFile(_ path: String, force: Bool) throws {
        cloudFilesExamined += 1
        guard let inventory = try cloudFileInventoryRow(path, database: db) else { return }
        // Only inventories enabled for this account are captured: nothing pumps the others, so their journal would grow
        // without limit (run 8). Enabling one later takes it through its own cut.
        if let enabled = cloudEnabledRows, !enabled.contains(inventory) { return }
        let source = try DeckMemoryCloudSchema.safePath(path, root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let state = try CloudDeleteState(memory: db)
        if try state.intent(at: path) != nil {
            // Decision 3: one file at a time. A delete that cannot be finished now waits; nothing else waits for it.
            let finished: CloudIntentFinish
            do { finished = try cloudFinishMemoryIntent(path) } catch {
                CloudSyncDiagnostics.shared.info("memory: a delete will be finished later on this Mac; nothing else waits for it.")
                return
            }
            // Refused before it was journaled: the file is an ordinary file again and is captured as usual below.
            guard finished == .keptNewer || finished == .none else { return }
        }
        // Local-only files never escape through force capture, a watcher save or a cut.
        if try state.mark(at: path)?.mark == .onlyOnThisMac { return }
        let marked = try state.mark(at: path) != nil
        let previous = try db.first("SELECT hash,bytes,mtime FROM cloud_memory_files WHERE path=?", [.text(path)])
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text("deleteRule:seen:" + path), .text(String(cloudNowMs()))])
        try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("deleteRule:gone:" + path)])
        // The place is here again: an earlier recorded move away from it no longer applies.
        try cloudForgetRecordedMove(path)
        if !marked, !force, let previous, previous.int(1) == size, previous.double(2) == mtime { return }
        let hash = try cloudHashFile(source)
        // Never forge a removal by uploading marker-shaped file bytes, whatever labels they contain.
        if size < 16_384, let data = try? Data(contentsOf: source), DeckMemoryRemoval.parse(data) != nil {
            if !path.hasPrefix("archive/") {
                try db.run("DELETE FROM cloud_memory_control WHERE key='oneRule:stubs'")
                cloudOneRuleList = nil
            }
            return
        }
        if marked, try cloudMemoryReappeared(path, hash: hash) { return }
        // Rebuilt app state: a Cloud-only head re-establishes the local-only mark before these bytes can upload.
        let returning = try db.first("SELECT 1 FROM cloud_memory_control WHERE key=?", [.text("deleteRule:returning:" + path)]) != nil
        if !marked, !returning, let head = try cloudNewestMemoryHead(path), try cloudIsRemoval(hash: head.hash), let bytes = try cloudMemoryHeadBytes(head, path: path), let removal = DeckMemoryRemoval.parse(bytes),
           case .intent(let intent) = try? CloudDeleteTravel.read(removal.travel, place: path, mac: removal.by, at: removal.at), intent.scope == .cloud {
            try state.putMark(.init(place: path, mark: .onlyOnThisMac, at: intent.at))
            return
        }
        if let priorHash = previous?.string(0) { try cloudMemoryRememberHash(priorHash, path: path) }
        try cloudMemoryRememberHash(hash, path: path)
        if !marked, previous?.text(0) == hash {
            try db.run("UPDATE cloud_memory_files SET bytes=?,mtime=? WHERE path=?", [.int(size),.real(mtime),.text(path)]); return
        }
        let kept = try cloudVersionsFolder().appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: kept.path) {
            try FileManager.default.copyItem(at: source, to: kept)
            try BackendCloudBrainMemoryHash.synchronize(kept)
        }
        guard try cloudHashFile(kept) == hash, try cloudHashFile(source) == hash else { throw CloudFailure.versionChanged }
        let storeId = try cloudStoreId()
        try db.transaction {
            let origin = try db.first("SELECT store_id,resource_key,version FROM cloud_memory_file_origins WHERE path=?", [.text(path)])
            try db.run("INSERT INTO cloud_memory_journal(inventory,resource_key,file,hash,base_version,source_store) VALUES (?,?,?,?,?,?)",
                       [.text(inventory),.text(origin?.text(1) ?? "file/" + path),.text(kept.path),.text(hash),.optional(origin?.string(2)),.text(origin?.text(0) ?? storeId)])
            try db.run("INSERT INTO cloud_memory_files(path,hash,bytes,mtime) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET hash=excluded.hash,bytes=excluded.bytes,mtime=excluded.mtime", [.text(path),.text(hash),.int(size),.real(mtime)])
            try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("deleteRule:returning:" + path)])
        }
    }
    func cloudJournal(after: Int64, row: String) throws -> DeckMemoryCloudResource? {
        var after = after
        let storeId = try cloudStoreId()
        while let r = try db.first("SELECT seq,resource_key,body,file,hash,base_version,source_store FROM cloud_memory_journal WHERE seq>? AND inventory=? ORDER BY seq LIMIT 1", [.int(after),.text(row)]) {
            if let file = r.string(3) {
                if r.text(1).hasPrefix("file/"), try !cloudIsRemoval(hash: r.text(4)),
                   let path = try cloudPlacementPath(String(r.text(1).dropFirst(5)), origin: r.string(6) ?? storeId),
                   try CloudDeleteState(memory: db).mark(at: path)?.mark == .onlyOnThisMac {
                    // Lead's decision 4: a waiting edit is dropped ONLY for "Only on this Mac". For "Not on this Mac" (a
                    // hand delete) it still goes to the Cloud first, so his last text is never lost everywhere.
                    // Real removal markers still travel.
                    try db.run("DELETE FROM cloud_memory_journal WHERE seq=?", [.int(r.int(0))])
                    after = r.int(0)
                    continue
                }
                let currentCopy = try cloudVersionsFolder().appendingPathComponent(r.text(4))
                let url = FileManager.default.fileExists(atPath: currentCopy.path) ? currentCopy : URL(fileURLWithPath: file)
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                return .init(sequence: r.int(0), row: row, key: r.text(1), hash: r.text(4), bytes: size, data: nil, file: url, originStoreId: r.string(6), baseVersion: r.string(5))
            }
            guard let raw = r.data(2) else { throw CloudFailure.invalidRequest }
            let (t, values) = try DeckMemoryCloudSchema.decodeRow(raw)
            if Self.cloudFileLabelTables.contains(t.name), let column = t.columns.firstIndex(of: "path"),
               case .text(let path) = values[column], try CloudDeleteState(memory: db).mark(at: path) != nil {
                try db.run("DELETE FROM cloud_memory_journal WHERE seq=?", [.int(r.int(0))])
                after = r.int(0)
                continue
            }
            // MAC-NEXT-8: the board's live status stays here; what an older build queued for it is dropped.
            // MAC-NEXT-8b: a removal here is history and sends nothing (S15), except a shared setting's tombstone.
            if DeckMemoryCloudSchema.isLocalOnly(t) || (r.text(4) == Self.cloudJournalRemoved && t.name != "settings") {
                try db.run("DELETE FROM cloud_memory_journal WHERE seq=?", [.int(r.int(0))])
                after = r.int(0)
                continue
            }
            let resource = try cloudLogicalRow(t, values: values, database: db, storeId: storeId, sequence: r.int(0), row: row, baseVersion: r.string(5))
            // Y3: a journal row for something that arrived from the Cloud and was not changed here (the index writing an
            // arrived file's labels, for example) is dropped, never sent back as this Mac's own change.
            if try cloudIsEcho(resource, table: t, values: values, database: db, storeId: storeId) {
                try db.run("DELETE FROM cloud_memory_journal WHERE seq=?", [.int(r.int(0))])
                after = r.int(0)
                continue
            }
            return resource
        }
        return nil
    }
    /// Journal rows below `sequence` already have a durable LocalReceipt; remove them and any retained byte copy that no
    /// remaining journal row needs, so the account database does not grow without limit (finding 8).
    func cloudPruneJournal(row: String, before sequence: Int64) throws {
        guard sequence > 0 else { return }
        let files = try db.rows("SELECT DISTINCT hash FROM cloud_memory_journal WHERE inventory=? AND seq<? AND file IS NOT NULL", [.text(row),.int(sequence)]).map { $0.text(0) }
        try db.run("DELETE FROM cloud_memory_journal WHERE inventory=? AND seq<?", [.text(row),.int(sequence)])
        // Minted versions of rows the cursor is past are never re-read again.
        try db.run("DELETE FROM cloud_memory_seq_versions WHERE inventory=? AND seq<?", [.text(row),.int(sequence)])
        let versions = try cloudVersionsFolder()
        for hash in files where hash.utf8.count == 64 {
            guard try db.first("SELECT 1 FROM cloud_memory_journal WHERE hash=? LIMIT 1", [.text(hash)]) == nil else { continue }
            try? FileManager.default.removeItem(at: versions.appendingPathComponent(hash))
        }
    }
    func cloudCaptureFailure() throws -> Bool {
        try db.first("SELECT value FROM cloud_memory_control WHERE key='captureProblem'") != nil
    }
    /// Read connection to one snapshot's copies, reused for every page (was one open per row).
    func cloudSnapshotReader(_ snapshot: DeckMemoryCloudSnapshot) throws -> DeckMemoryDatabase {
        let key = snapshot.root.standardizedFileURL.path
        if let open = cloudSnapshotReaders[key] { return open }
        let reader = try DeckMemoryDatabase(path: snapshot.root.appendingPathComponent("memory.db").path, readOnly: true)
        let cloudCopy = snapshot.root.appendingPathComponent("memory-cloud.db")
        if FileManager.default.fileExists(atPath: cloudCopy.path) { try reader.run("ATTACH DATABASE ? AS cloud", [.text(cloudCopy.path)]) }
        cloudSnapshotReaders[key] = reader
        return reader
    }
    func cloudCloseSnapshotReaders() {
        for reader in cloudSnapshotReaders.values { reader.close() }
        cloudSnapshotReaders = [:]
    }
    /// The last page of a row's cut: its coverage may now read complete (subject to pending journal rows).
    func cloudFinishSnapshot(_ snapshot: DeckMemoryCloudSnapshot, row: String) throws {
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text("cutComplete:" + row),.text("1")])
        // R4: the cut covers the append-only tables up to their end at the cut; later rows were journaled by capture.
        if let reader = cloudSnapshotReaders[snapshot.root.standardizedFileURL.path] {
            for t in DeckMemoryCloudSchema.tables where t.row == row { cloudRecordHighWater(t.name, database: reader) }
        }
        if let reader = cloudSnapshotReaders.removeValue(forKey: snapshot.root.standardizedFileURL.path) { reader.close() }
    }
    /// A new cut after an interruption: every row must finish again before it may read complete.
    func cloudResetCutState() throws {
        try db.run("DELETE FROM cloud_memory_control WHERE key LIKE 'cutComplete:%'")
        cloudMemorySnapshots = [:]
    }
    /// M7: at most one staged copy. Anything under this account's snapshots folder other than the current cut goes.
    func cloudKeepOnlySnapshot(id: String) throws {
        guard let state = cloudStateRoot else { return }
        let folder = state.appendingPathComponent("snapshots", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name != id {
            let gone = folder.appendingPathComponent(name)
            if let reader = cloudSnapshotReaders.removeValue(forKey: gone.standardizedFileURL.path) { reader.close() }
            try FileManager.default.removeItem(at: gone)
        }
        cloudMemorySnapshots = cloudMemorySnapshots.filter { $0.key == id }
    }
    /// M7/M10: once the cut is published (bootstrap returned) or the setup is abandoned, no staged copy is kept.
    func cloudDiscardSnapshots() throws {
        cloudCloseSnapshotReaders()
        cloudMemorySnapshots = [:]
        guard let state = cloudStateRoot else { return }
        let folder = state.appendingPathComponent("snapshots", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    /// M10 retention, the safe part: an exported part whose version is no longer this account's current head for that
    /// resource was durably queued before its successor (journal order) and is never replayed again, so it is dropped.
    /// Current heads keep their exact operation bytes (a replay must be byte-identical); imported parts are kept.
    func cloudPruneSupersededParts() throws {
        let storeId = try cloudStoreId()
        try db.run("DELETE FROM cloud_memory_parts WHERE store_id=? AND NOT EXISTS (SELECT 1 FROM cloud_memory_export_heads h WHERE h.resource_key = cloud_memory_parts.store_id || ':' || cloud_memory_parts.resource_key AND h.version = cloud_memory_parts.revision) AND NOT EXISTS (SELECT 1 FROM cloud_memory_journal j WHERE j.resource_key = cloud_memory_parts.resource_key)", [.text(storeId)])
    }
}

/// Per-store test hooks for the delete rule (the shared witness slot can be installed only once per process) and this
/// process's start time. Production never sets a hook: every store then asks `CloudDeleteWitnessSlot.shared`.
final class DeckMemoryDeleteRuleHooks: @unchecked Sendable {
    static let shared = DeckMemoryDeleteRuleHooks()
    /// When this process started (the kernel's own record); the first use's time when it cannot be read (later, so
    /// more counts as by hand: the safe side).
    static let processStartedAt: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, info.kp_proc.p_un.__p_starttime.tv_sec > 0 else { return Date() }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }()
    private let lock = NSLock()
    private var slots: [ObjectIdentifier: CloudDeleteWitnessSlot] = [:]
    private var starts: [ObjectIdentifier: Int64] = [:]
    func set(slot: CloudDeleteWitnessSlot, runStartedAt: Int64?, for store: ObjectIdentifier) {
        lock.withLock { slots[store] = slot; starts[store] = runStartedAt }
    }
    func slot(for store: ObjectIdentifier) -> CloudDeleteWitnessSlot? { lock.withLock { slots[store] } }
    func runStartedAt(for store: ObjectIdentifier) -> Int64? { lock.withLock { starts[store] } }
}
