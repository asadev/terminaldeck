import Foundation
import CoreServices
import TerminalDeckNativeCore

/// File events for the memory folder (no polling). Calls back with the paths that changed.
final class DeckMemoryWatcher: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let event: @Sendable ([String], Bool) -> Void
        init(_ event: @escaping @Sendable ([String], Bool) -> Void) { self.event = event }
    }
    private let queue = DispatchQueue(label: "dev.terminaldeck.deck-memory-events", qos: .utility)
    private var reference: FSEventStreamRef?
    private let box: Box
    init?(root: String, event: @escaping @Sendable ([String], Bool) -> Void) {
        box = Box(event)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }; _ = Unmanaged<Box>.fromOpaque(pointer).retain(); return pointer
        }, release: { pointer in if let pointer { Unmanaged<Box>.fromOpaque(pointer).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let values = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let broad = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
            let rescan = (0..<count).contains { flags[$0] & broad != 0 }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().event((0..<count).map { String(cString: values[$0]) }, rescan)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return nil }
        reference = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }
    func stop() {
        guard let reference else { return }
        self.reference = nil
        FSEventStreamStop(reference); FSEventStreamInvalidate(reference); FSEventStreamRelease(reference)
    }
    deinit { stop() }
}

// The folder itself: bringing the index in line with the disk, moving, backing up, importing, folding a helper seat back.
extension DeckMemoryStore {
    public func location() async -> DeckMemoryLocation {
        let previous = dataRoot.flatMap(DeckMemoryPaths.readPointer)?.previous.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? []
        return .init(root: root, defaultRoot: DeckMemoryPaths.defaultRoot(dataRoot: dataRoot), previousRoots: previous)
    }

    // MARK: The index follows the disk

    func startWatching() {
        guard watching, !closed else { return }
        watcher?.stop()
        // FSEvents reports real paths, so /tmp-style links are resolved before comparing.
        let base = root.resolvingSymlinksInPath().path
        watcher = DeckMemoryWatcher(root: base) { [weak self] paths, rescan in
            Task { await self?.filesChanged(paths, rescan: rescan, base: base) }
        }
    }
    func filesChanged(_ paths: [String], rescan: Bool, base: String) {
        guard !closed, base == root.resolvingSymlinksInPath().path else { return }
        // The database's own files change with every write: they are never a reason to look again.
        let relevant = paths.filter { path in
            guard path.hasPrefix(base + "/") else { return path == base }
            let relative = String(path.dropFirst(base.count + 1))
            return !relative.hasPrefix("memory.db") && !relative.hasPrefix("archive/versions/") && !relative.hasPrefix("archive/backups/")
                && !relative.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        guard rescan || !relevant.isEmpty else { return }
        if relevant.contains(base) { _ = try? reindexNow(); kickEmbedding(); return }
        if rescan { _ = try? reindexNow() }
        else {
            let relative = Array(Set(relevant.map { String($0.dropFirst(base.count + 1)) }))
            // Keep large event batches below SQLite's binding and expression limits.
            for offset in stride(from: 0, to: relative.count, by: 100) {
                _ = try? reindexNow(paths: Array(relative[offset..<min(offset + 100, relative.count)]))
            }
        }
        kickEmbedding()
    }

    public func reindex() async throws -> DeckMemoryReindexReport {
        let report = try reindexNow()
        kickEmbedding()
        return report
    }
    /// Walks the folder and brings every index row in line with its file. Files that are gone are marked
    /// missing (never dropped), so they come back by themselves if the file does.
    func reindexNow(paths: [String]? = nil) throws -> DeckMemoryReindexReport {
        if let paths, paths.isEmpty { return DeckMemoryReindexReport() }
        var report = DeckMemoryReindexReport()
        var changed = Set<DeckMemoryChange>()
        // Match the full walk's rule: never follow a shortcut, including one in a parent folder.
        var checked = Set<String>()
        func safePath(_ path: String) -> Bool {
            var file = root
            for part in path.split(separator: "/") {
                file.appendPathComponent(String(part))
                if checked.contains(file.path) { continue }
                if (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType == .typeSymbolicLink { return false }
                checked.insert(file.path)
            }
            return true
        }
        // Directory events also cover renames and deletions of whole subtrees.
        let files = paths.map { paths in
            Array(Set(paths.flatMap { path -> [String] in
                guard safePath(path) else { return [] }
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url(path).path, isDirectory: &directory), directory.boolValue {
                    return DeckMemoryFiles.markdown(under: url(path), skip: { let item = path + "/" + $0; return item == "archive/versions" || item == "archive/backups" }).map { path + "/" + $0 }
                }
                return [path]
            }))
        } ?? DeckMemoryFiles.markdown(under: root, skip: { $0 == "archive/versions" || $0 == "archive/backups" })
        var known: [String: (mtime: Double, bytes: Int64)] = [:]
        for table in ["notes", "topics", "files", "handoffs"] {
            let scope = paths.map { paths in " AND (" + paths.map { _ in "path = ? OR path LIKE ? ESCAPE '!'" }.joined(separator: " OR ") + ")" } ?? ""
            let args: [DeckMemorySQL] = (paths ?? []).flatMap { (path: String) -> [DeckMemorySQL] in
                let escaped = path.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_")
                return [.text(path), .text(escaped + "/%")]
            }
            for row in try db.rows("SELECT path, mtime, bytes FROM \(table) WHERE missing = 0" + scope, args) { known[row.text(0)] = (row.double(1) ?? 0, row.int(2)) }
        }
        var seen = Set<String>()
        try db.transaction {
            for path in files {
                let template = DeckMemoryFiles.templateCategory(path), kind = DeckMemoryFiles.classify(path)
                guard template != nil || kind != nil, let info = DeckMemoryFiles.info(url(path)) else { continue }
                report.scanned += 1; seen.insert(path)
                if let before = known[path], before.mtime == info.mtime, before.bytes == Int64(info.bytes) { continue }
                guard let text = DeckMemoryFiles.read(url(path)) else { continue }
                let isNew = known[path] == nil
                var didChange = false
                if let template {
                    didChange = try trackIfChanged(path, kind: "template", ownerKey: "template:" + template.rawValue, text: text)
                    if didChange { changed.insert(Self.changeKey(.templates, nil, template.rawValue)) }
                } else if let kind {
                    switch kind.kind {
                    case .note(let archived):
                        if let result = try indexNote(path: path, pathOwner: kind.owner, archivedByPath: archived, text: text), result.changed {
                            didChange = true; changed.insert(Self.changeKey(.notes, try noteRow(result.id).flatMap { DeckMemoryOwner(key: $0.text(4)) } ?? kind.owner, result.id))
                        }
                    case .topic(let id):
                        didChange = try indexTopic(path: path, owner: kind.owner, id: id, text: text)
                        if didChange { changed.insert(Self.changeKey(.topics, kind.owner, id)) }
                    case .card:
                        didChange = try trackIfChanged(path, kind: "card", ownerKey: kind.owner.key, text: text)
                        if didChange { changed.insert(Self.changeKey(.card, kind.owner)) }
                    case .playbook:
                        didChange = try trackIfChanged(path, kind: "playbook", ownerKey: kind.owner.key, text: text)
                        if didChange { changed.insert(Self.changeKey(.playbook, kind.owner)) }
                    case .document(let name):
                        didChange = try trackIfChanged(path, kind: "document", ownerKey: kind.owner.key, text: text)
                        if didChange { changed.insert(Self.changeKey(.documents, kind.owner, name)) }
                    case .handoff(let topic, let archived):
                        if let result = try indexHandoff(path: path, pathOwner: kind.owner, topic: topic, archivedByPath: archived, text: text), result.changed {
                            didChange = true; changed.insert(Self.changeKey(.topics, kind.owner, "handoff:" + result.id))
                        }
                    }
                }
                if didChange { if isNew { report.added += 1 } else { report.changed += 1 } }
            }
            for (path, _) in known where !seen.contains(path) && !FileManager.default.fileExists(atPath: url(path).path) {
                report.missing += 1
                if let row = try db.first("SELECT id, owner FROM notes WHERE path = ?", [.text(path)]) {
                    try db.run("UPDATE notes SET missing = 1 WHERE path = ?", [.text(path)])
                    noteFiles[row.text(0)] = nil
                    try removeSearch(kind: .note, ref: row.text(0)); changed.insert(Self.changeKey(.notes, DeckMemoryOwner(key: row.text(1)), row.text(0)))
                } else if let row = try db.first("SELECT owner, id FROM topics WHERE path = ?", [.text(path)]) {
                    try db.run("UPDATE topics SET missing = 1 WHERE path = ?", [.text(path)])
                    try removeSearch(kind: .topic, ref: row.text(0) + "/" + row.text(1)); changed.insert(Self.changeKey(.topics, DeckMemoryOwner(key: row.text(0)), row.text(1)))
                } else if let row = try db.first("SELECT id, owner, topic FROM handoffs WHERE path = ?", [.text(path)]) {
                    try db.run("UPDATE handoffs SET missing = 1 WHERE path = ?", [.text(path)])
                    try removeSearch(kind: .topic, ref: Self.handoffRef(ownerKey: row.text(1), topic: row.string(2), id: row.text(0)))
                    changed.insert(Self.changeKey(.topics, DeckMemoryOwner(key: row.text(1)), "handoff:" + row.text(0)))
                } else if let row = try db.first("SELECT kind, owner FROM files WHERE path = ?", [.text(path)]) {
                    try db.run("UPDATE files SET missing = 1 WHERE path = ?", [.text(path)])
                    let owner = DeckMemoryOwner(key: row.text(1))
                    switch row.text(0) {
                    case "card": if let owner { try removeSearch(kind: .card, ref: owner.key) }; changed.insert(Self.changeKey(.card, owner))
                    case "playbook": if let owner { try removeSearch(kind: .playbook, ref: owner.key) }; changed.insert(Self.changeKey(.playbook, owner))
                    case "template": changed.insert(Self.changeKey(.templates, nil, row.text(1).replacingOccurrences(of: "template:", with: "")))
                    default: changed.insert(Self.changeKey(.documents, owner))
                    }
                }
            }
        }
        for change in changed { post(change.area, change.owner, change.ref) }
        if report.added + report.changed + report.missing > 0 { post(.index) }
        return report
    }
    /// One entry per thing that changed during a walk, so each is announced once.
    static func changeKey(_ area: DeckMemoryChange.Area, _ owner: DeckMemoryOwner?, _ ref: String? = nil) -> DeckMemoryChange {
        .init(area: area, owner: owner, ref: ref, at: Date(timeIntervalSince1970: 0))
    }
    /// For files kept by path (cards, playbooks, templates, documents). True when the text is not what the index had.
    func trackIfChanged(_ path: String, kind: String, ownerKey: String, text: String) throws -> Bool {
        let hash = DeckMemoryFiles.hash(text)
        let known = try db.first("SELECT hash, missing FROM files WHERE path = ?", [.text(path)])
        try trackFile(path, kind: kind, ownerKey: ownerKey, text: text)
        return known == nil || known?.text(0) != hash || known?.int(1) != 0
    }

    // MARK: Backup

    public func backup() async throws -> URL {
        let folder = url("archive/backups")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw DeckMemoryError(.io, "The backups folder could not be made: \(error.localizedDescription)") }
        let target = folder.appendingPathComponent("memory-" + DeckMemoryFiles.compact(now()) + "-" + DeckMemoryFiles.shortID() + ".db")
        try db.run("VACUUM INTO ?", [.text(target.path)])
        // Backups are copies of what is still in memory.db, so only the newest ones are kept.
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("memory-") && $0.hasSuffix(".db") }.sorted()
        for old in all.dropLast(7) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        try setSetting(DeckMemoryFiles.stamp(now()), key: "backup.last", owner: nil)
        return target
    }

    // MARK: Move…

    static func everyFile(under folder: URL) -> [String] {
        var found: [String] = []
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        let base = folder.standardizedFileURL.path
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = file.standardizedFileURL.path
            if path.hasPrefix(base + "/") { found.append(String(path.dropFirst(base.count + 1))) }
        }
        return found.sorted()
    }
    public func move(to newRoot: URL) async throws -> DeckMemoryMoveReport {
        let from = root, to = newRoot.standardizedFileURL, files = FileManager.default
        guard to.path.hasPrefix("/"), to.path != from.path else { throw DeckMemoryError(.invalid, "Choose a different folder to move the memory to.") }
        guard !to.path.hasPrefix(from.path + "/"), !from.path.hasPrefix(to.path + "/") else { throw DeckMemoryError(.invalid, "The new folder cannot be inside the memory folder, or contain it.") }
        if let dataRoot, to.path == dataRoot.standardizedFileURL.path { throw DeckMemoryError(.invalid, "That folder is the app's own data folder.") }
        var isDirectory: ObjCBool = false
        let existed = files.fileExists(atPath: to.path, isDirectory: &isDirectory)
        if existed {
            guard isDirectory.boolValue else { throw DeckMemoryError(.invalid, "There is already a file at that place.") }
            let inside = ((try? files.contentsOfDirectory(atPath: to.path)) ?? []).filter { $0 != ".DS_Store" }
            guard inside.isEmpty else { throw DeckMemoryError(.invalid, "That folder already has things in it. Choose an empty folder, or a new name.") }
        }
        // Quiet first: no watcher, no half-written database.
        watcher?.stop(); watcher = nil
        embedTask?.cancel(); embedTask = nil
        db.close()
        func reopen(_ at: URL) throws { db = try DeckMemoryDatabase(path: at.appendingPathComponent("memory.db").path) }
        var copied = 0, bytes: Int64 = 0
        do {
            let list = Self.everyFile(under: from)
            try files.createDirectory(at: to, withIntermediateDirectories: true)
            for relative in list {
                let target = to.appendingPathComponent(relative)
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: from.appendingPathComponent(relative), to: target)
            }
            // Read every copy back and compare it with its original, byte for byte.
            for relative in list {
                let original = try Data(contentsOf: from.appendingPathComponent(relative), options: .mappedIfSafe)
                let copy = try Data(contentsOf: to.appendingPathComponent(relative), options: .mappedIfSafe)
                guard DeckMemoryFiles.hash(original) == DeckMemoryFiles.hash(copy) else {
                    throw DeckMemoryError(.moveFailed, "\(relative) did not copy correctly.")
                }
                copied += 1; bytes += Int64(original.count)
            }
            guard Set(Self.everyFile(under: to)) == Set(list) else { throw DeckMemoryError(.moveFailed, "The copy does not hold the same files as the original.") }
            try reopen(to)
        } catch {
            // Nothing was switched: remove only what this move made, and carry on from the old folder.
            if !existed { try? files.removeItem(at: to) }
            else { for name in (try? files.contentsOfDirectory(atPath: to.path)) ?? [] { try? files.removeItem(at: to.appendingPathComponent(name)) } }
            try reopen(from)
            startWatching(); kickEmbedding()
            throw (error as? DeckMemoryError) ?? DeckMemoryError(.moveFailed, "The memory folder could not be moved, so nothing was changed: \(error.localizedDescription)")
        }
        root = to
        if let dataRoot {
            var previous = DeckMemoryPaths.readPointer(dataRoot: dataRoot)?.previous ?? []
            previous.removeAll { $0 == from.path || $0 == to.path }
            previous.append(from.path)
            try? DeckMemoryPaths.writePointer(.init(root: to.path, previous: previous), dataRoot: dataRoot)
        }
        // The old folder is left exactly as it was, plus one line saying where the memory went.
        try? DeckMemoryFiles.write("# This memory folder was moved\n\nOn \(DeckMemoryFiles.day(now())) Terminal Deck moved its memory to:\n\n    \(to.path)\n\nThis folder is kept as it was on that day, as an archive. The app no longer reads or writes here.\n",
                                   to: from.appendingPathComponent("MOVED.md"))
        onRootChanged?(to)
        startWatching(); kickEmbedding()
        post(.folder)
        return .init(from: from, to: to, files: copied, bytes: bytes, verified: true)
    }

    // MARK: Import (copy only; the source is never changed)

    static let importMaxFiles = 2000
    static let importMaxBytes = 256 * 1024
    static func importLabel(_ source: URL) -> String {
        var name = source.lastPathComponent
        // ".../<project>/memory" says nothing by itself: take the folder above.
        if ["memory", "memories", "notes"].contains(name.lowercased()) { name = source.deletingLastPathComponent().lastPathComponent }
        return DeckMemoryOwner.slug(name)
    }
    public func importFolder(_ source: URL, into owner: DeckMemoryOwner, label: String?) async throws -> DeckMemoryImportReport {
        try importNow(source, into: owner, label: label, sourceName: "import")
    }
    /// `origin`: what to write as "imported_from" in front of each file's own path. nil = the source folder's full path.
    func importNow(_ source: URL, into owner: DeckMemoryOwner, label: String?, sourceName: String, origin: String? = nil) throws -> DeckMemoryImportReport {
        let from = source.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: from.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DeckMemoryError(.notFound, "There is no folder at \(source.path).")
        }
        let here = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard from.path != here, !from.path.hasPrefix(here + "/") else { throw DeckMemoryError(.invalid, "That folder is already inside the memory folder.") }
        let name = DeckMemoryOwner.slug(label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? Self.importLabel(from))
        let folder = owner.notesFolder + "/imported/" + name
        var report = DeckMemoryImportReport(source: from, owner: owner, folder: folder, verified: true)
        _ = try ensureOwnerNow(owner, name: nil)
        let list = DeckMemoryFiles.markdown(under: from, depth: 4, limit: Self.importMaxFiles + 1)
        if list.count > Self.importMaxFiles { report.skipped.append("Only the first \(Self.importMaxFiles) notes were taken; this folder has more.") }
        for relative in list.prefix(Self.importMaxFiles) {
            let file = from.appendingPathComponent(relative)
            guard let info = DeckMemoryFiles.info(file) else { report.skipped.append("\(relative): it could not be read."); continue }
            guard info.bytes <= Self.importMaxBytes else { report.skipped.append("\(relative): larger than 256 KB."); continue }
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                report.skipped.append("\(relative): it is not plain text."); continue
            }
            let target = folder + "/" + relative, sourceHash = DeckMemoryFiles.hash(text)
            let existing = DeckMemoryFiles.read(url(target)).map(DeckMemoryFile.init(text:))
            let cameFrom = origin.map { $0 + "/" + relative } ?? file.path
            // Unchanged means the same text AND the same record of where it came from.
            if let existing, existing.value("source_hash") == sourceHash, existing.value("imported_from") == cameFrom, let id = existing.value("id") {
                report.unchanged += 1; report.noteIDs.append(id); continue
            }
            // The copy is the source's own text with the app's labels added to the block on top; nothing of the source is dropped.
            var copy = DeckMemoryFile(text: text)
            // A label of the source that the app's own label would replace is kept beside it, as "original_<name>".
            for key in ["id", "date", "source", "project", "session", "seat", "category", "hire", "hand", "job", "owner", "agent"] {
                if let value = copy.value(key) { copy.set("original_" + key, value) }
            }
            let id = existing?.value("id") ?? Self.newNoteID(Date(timeIntervalSince1970: info.mtime))
            let labels = DeckMemoryLabels(owner: owner, project: owner.projectID, date: Date(timeIntervalSince1970: info.mtime), type: copy.value("type") ?? "note")
            Self.stampLabels(&copy, id: id, type: labels.type, labels: labels, source: sourceName)
            // When it became true: the source's own valid_from, kept exactly as written, when it reads as a date;
            // else when its source was last written, never when it was imported. A valid_from that is not a date is
            // kept beside it as original_valid_from.
            if DeckMemoryFiles.date(copy.value("valid_from")) == nil {
                if let unreadable = copy.value("valid_from") { copy.set("original_valid_from", unreadable) }
                copy.set("valid_from", DeckMemoryFiles.stamp(labels.date))
            }
            copy.set("imported_from", cameFrom); copy.set("source_hash", sourceHash)
            if existing != nil { keepVersion(of: target) }
            try DeckMemoryFiles.write(copy.text, to: url(target))
            // Read the copy back: its body must be the source's body, and every label the source had must still be there.
            let original = DeckMemoryFile(text: text)
            if let back = DeckMemoryFiles.read(url(target)).map(DeckMemoryFile.init(text:)), back.body == original.body,
               original.keys.allSatisfy({ back.value($0) == original.value($0) || back.value("original_" + $0) == original.value($0) }) {
                try indexNote(path: target, pathOwner: owner, archivedByPath: false, text: nil)
                report.noteIDs.append(id)
                if existing == nil { report.imported += 1 } else { report.updated += 1 }
            } else {
                report.verified = false; report.skipped.append("\(relative): the copy did not match the original.")
            }
        }
        if report.imported + report.updated > 0 { post(.notes, owner); kickEmbedding() }
        return report
    }
    public func migrateHootMemory() async throws -> DeckMemoryImportReport {
        guard let dataRoot else { throw DeckMemoryError(.unavailable, "This memory was opened without the app's data folder, so there is no old Hoot memory to bring in.") }
        let old = RNMHootPaths(dataRoot: dataRoot).memory
        guard FileManager.default.fileExists(atPath: old.path) else {
            return .init(source: old, owner: .hoot, folder: DeckMemoryOwner.hoot.notesFolder + "/imported/hoot-memory", verified: true)
        }
        // Recorded by its place inside the app's own data, so the label reads the same in every copy of the app.
        let report = try importNow(old, into: .hoot, label: "hoot-memory", sourceName: "migration", origin: "the app's data: hoot/memory")
        try setSetting(DeckMemoryFiles.stamp(now()), key: "migration.hoot.last", owner: nil)
        return report
    }

    // MARK: A helper seat folds back into its parent

    public func foldBack(_ helper: DeckMemoryOwner, into parent: DeckMemoryOwner?) async throws -> DeckMemoryFoldReport {
        guard case .role = helper else { throw DeckMemoryError(.invalid, "Only a helper role seat can be folded back.") }
        let recorded = try setting(DeckMemoryKeys.seatParent, owner: helper).flatMap(DeckMemoryOwner.init(key:))
        guard let target = parent ?? recorded else { throw DeckMemoryError(.invalid, "This seat has no parent seat recorded, so say which seat its notes go to.") }
        guard target.isSeat, target != helper else { throw DeckMemoryError(.invalid, "A helper seat folds back into another seat.") }
        _ = try ensureOwnerNow(target, name: nil)
        var report = DeckMemoryFoldReport(from: helper, into: target, notes: 0, topics: 0)
        let files = FileManager.default
        func free(_ wanted: String) -> String {
            var path = wanted, counter = 1
            while files.fileExists(atPath: url(path).path) { counter += 1; path = String(wanted.dropLast(3)) + "-\(counter).md" }
            return path
        }
        // Notes: same id, same history, now the parent seat's. Archived ones stay archived, under the parent's path.
        for row in try db.rows("SELECT id, path, archived FROM notes WHERE owner = ? AND missing = 0", [.text(helper.key)]) {
            let path = row.text(1), archived = !row.isNull(2)
            guard var file = DeckMemoryFiles.read(url(path)).map(DeckMemoryFile.init(text:)) else { continue }
            let live = archived && path.hasPrefix("archive/") ? String(path.dropFirst("archive/".count)) : path
            let prefix = helper.notesFolder + "/"
            let rest = live.hasPrefix(prefix) ? String(live.dropFirst(prefix.count)) : (live as NSString).lastPathComponent
            let moved = free((archived ? "archive/" : "") + target.notesFolder + "/" + rest)
            file.set("seat", target.key); file.set("owner", nil); file.set("category", target.category?.rawValue)
            file.set("project", target.projectID ?? file.value("project")); file.set("folded_from", helper.key)
            try DeckMemoryFiles.write(file.text, to: url(path))
            do {
                try files.createDirectory(at: url(moved).deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: url(path), to: url(moved))
            } catch { throw DeckMemoryError(.io, "A note could not be moved to the parent seat: \(error.localizedDescription)") }
            try indexNote(path: moved, pathOwner: target, archivedByPath: archived, text: nil)
            if archived { try db.run("UPDATE notes SET origin_path = ? WHERE id = ?", [.text(target.notesFolder + "/" + rest), .text(row.text(0))]) }
            report.notes += 1
        }
        // Topics stay with their jobs, under the parent seat.
        for row in try db.rows("SELECT id, path FROM topics WHERE owner = ? AND missing = 0", [.text(helper.key)]) {
            let id = row.text(0), path = row.text(1)
            guard var file = DeckMemoryFiles.read(url(path)).map(DeckMemoryFile.init(text:)) else { continue }
            let moved = free(target.topicsFolder + "/" + id + ".md"), movedID = Self.stem(moved)
            file.set("seat", target.key); file.set("owner", nil); file.set("category", target.category?.rawValue)
            file.set("project", target.projectID ?? file.value("project")); file.set("folded_from", helper.key)
            try DeckMemoryFiles.write(file.text, to: url(path))
            do {
                try files.createDirectory(at: url(moved).deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: url(path), to: url(moved))
            } catch { throw DeckMemoryError(.io, "A topic could not be moved to the parent seat: \(error.localizedDescription)") }
            try db.run("UPDATE topics SET missing = 1, path = path || '#folded' WHERE owner = ? AND id = ?", [.text(helper.key), .text(id)])
            try removeSearch(kind: .topic, ref: helper.key + "/" + id)
            try indexTopic(path: moved, owner: target, id: movedID, text: nil)
            report.topics += 1
        }
        // The helper's own card and anything else left in its folder go to the archive; then the empty folder goes.
        let folder = url(helper.folder)
        for relative in Self.everyFile(under: folder) {
            let source = helper.folder + "/" + relative
            var destination = "archive/" + source, counter = 1
            while files.fileExists(atPath: url(destination).path) { counter += 1; destination = "archive/" + source + ".\(counter)" }
            try? files.createDirectory(at: url(destination).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.moveItem(at: url(source), to: url(destination))
            try db.run("UPDATE files SET missing = 1 WHERE path = ?", [.text(source)])
        }
        try? removeSearch(kind: .card, ref: helper.key)
        if Self.everyFile(under: folder).isEmpty { try? files.removeItem(at: folder) }
        try setSetting(target.key, key: DeckMemoryKeys.seatFoldedInto, owner: helper)
        // Said once in the parent's diary, so the history shows where these notes came from.
        _ = try appendNow(.init(stamp: .init(owner: target), role: .event,
            text: "The helper seat \(helper.key) closed. Its \(report.notes) notes and \(report.topics) topics are now in this seat."))
        post(.notes, target); post(.topics, target); post(.notes, helper); post(.folder)
        kickEmbedding()
        return report
    }
}
