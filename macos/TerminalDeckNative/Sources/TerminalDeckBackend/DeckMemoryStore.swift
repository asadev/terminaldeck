import Foundation
import TerminalDeckNativeCore

/// Sends every change to streams and the app's event channel.
final class DeckMemoryChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [UUID: AsyncStream<DeckMemoryChange>.Continuation] = [:]
    private var forward: (@Sendable (DeckMemoryChange) -> Void)?
    func setForward(_ forward: (@Sendable (DeckMemoryChange) -> Void)?) { lock.withLock { self.forward = forward } }
    func stream() -> AsyncStream<DeckMemoryChange> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { streams[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.streams.removeValue(forKey: id) } }
        }
    }
    func post(_ change: DeckMemoryChange) {
        let (listeners, forward) = lock.withLock { (Array(streams.values), self.forward) }
        listeners.forEach { $0.yield(change) }
        forward?(change)
    }
    func finish() { lock.withLock { let all = streams.values; streams = [:]; return Array(all) }.forEach { $0.finish() } }
}

/// The real Deck Memory store: Markdown files in one visible folder, indexed by `memory.db`.
public actor DeckMemoryStore: DeckMemoryStoring {
    var root: URL
    let dataRoot: URL?
    var db: DeckMemoryDatabase
    let hub = DeckMemoryChangeHub()
    let now: @Sendable () -> Date
    let embedder: (any DeckMemoryEmbedding)?
    let watching: Bool
    var watcher: DeckMemoryWatcher?
    var embedTask: Task<Void, Never>?
    var embeddingOff = false
    /// Texts without a vector from the current model have been queued since this opening (`queueMissingVectors`).
    var missingQueued = false
    var onRootChanged: (@Sendable (URL) -> Void)?
    var noteFiles: [String: (hash: String, file: DeckMemoryFile)] = [:]
    var closed = false
    /// Lines for the app's log about what this opening did once (the board history settle), read by the app after `open`.
    var openingLines: [String] = []

    /// Opens (and creates, the first time) the memory folder. `root` nil = the folder the app's rules give
    /// for this data folder (`DeckMemoryPaths.root`). Tests pass their own folders and `watch: false`.
    public static func open(root: URL? = nil, dataRoot: URL?, embedder: (any DeckMemoryEmbedding)? = DeckMemoryEmbedders.preferred(),
                            watch: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) async throws -> DeckMemoryStore {
        let store = try DeckMemoryStore(root: root ?? DeckMemoryPaths.root(dataRoot: dataRoot), dataRoot: dataRoot,
                                        embedder: embedder, watch: watch, now: now)
        try await store.start()
        return store
    }

    init(root: URL, dataRoot: URL?, embedder: (any DeckMemoryEmbedding)?, watch: Bool, now: @escaping @Sendable () -> Date) throws {
        self.root = root.standardizedFileURL; self.dataRoot = dataRoot; self.embedder = embedder; self.watching = watch; self.now = now
        do { try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true) }
        catch { throw DeckMemoryError(.io, "The memory folder could not be created at \(root.path): \(error.localizedDescription)") }
        db = try DeckMemoryDatabase(path: self.root.appendingPathComponent("memory.db").path)
    }

    func start() throws {
        migrateAgentFolders()
        for folder in ["hoot/notes", "hoot/topics", "projects", "roles", "templates", "archive"] {
            try? FileManager.default.createDirectory(at: url(folder), withIntermediateDirectories: true)
        }
        try writeStartHereFiles()
        for category in DeckMemoryCategory.allCases { try ensureTemplateFiles(category) }
        _ = try ensureOwnerNow(.hoot, name: "Hoot")
        _ = try reindexNow()
        try reembedIfModelChanged()
        // Housekeeping of a derived table: a failure here never keeps memory from opening (the next opening tries again).
        try? trimBoardHistory()
        // Once per store: the history cut back to what the settled writer keeps, after a copy of memory.db.
        do {
            if let settled = try settleBoardHistoryOnce(), settled.before != settled.after {
                openingLines.append("Memory: the board history was settled once: \(settled.before) entries -> \(settled.after) (only working/idle flips that did not hold \(Int(Self.boardSettleSeconds)) s; nothing else touched), in "
                    + String(format: "%.1f s", settled.seconds) + "; a copy of memory.db from before is " + (settled.backup.map { "archive/backups/" + $0.lastPathComponent } ?? "not needed") + ".")
            }
        } catch { openingLines.append("Memory: the one-time board history settle did not run (it tries again at the next start): " + error.localizedDescription) }
        startWatching()
        kickEmbedding()
    }
    /// Before spec 3a an agent had `agents/<name>/`. Memory belongs to the seat now: the folder becomes `roles/<name>/`.
    func migrateAgentFolders() {
        let files = FileManager.default, old = url("agents")
        guard let names = try? files.contentsOfDirectory(atPath: old.path) else { return }
        for name in names where !name.hasPrefix(".") {
            let target = url("roles/" + name)
            guard !files.fileExists(atPath: target.path) else { continue }
            try? files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.moveItem(at: old.appendingPathComponent(name), to: target)
        }
        if ((try? files.contentsOfDirectory(atPath: old.path)) ?? ["x"]).filter({ !$0.hasPrefix(".") }).isEmpty { try? files.removeItem(at: old) }
    }

    /// Vectors from different models cannot be compared. When the model changes (a new app brings a better one), every
    /// indexed text is queued once to get a vector from the new model, in the background; the old vectors go (they are
    /// derived, never memory itself). Until it is done, search by words works as always.
    func reembedIfModelChanged() throws {
        guard let embedder else { return }
        let key = "embedding.model"
        guard try setting(key, owner: nil) != embedder.model else { return }
        try db.transaction {
            try db.run("DELETE FROM embeddings WHERE model != ?", [.text(embedder.model)])
            try db.run("""
                INSERT OR IGNORE INTO embed_queue (kind, ref)
                SELECT m.kind, m.ref FROM search_map m
                WHERE m.kind != 'diary' OR m.ref IN (SELECT CAST(id AS TEXT) FROM diary WHERE role IN ('user', 'assistant') AND length(text) >= 12)
                """)
            try setSetting(embedder.model, key: key, owner: nil)
        }
    }
    /// Stops watching and closes the database. The files stay as they are.
    public func close() {
        closed = true; watcher?.stop(); watcher = nil; embedTask?.cancel(); embedTask = nil; db.close(); noteFiles.removeAll(); hub.finish()
    }
    /// What this opening did once, for the app's log (empty on most openings).
    public func openingReport() -> [String] { openingLines }
    /// The app hears about a move here (so `DeckMemory.root` follows it).
    public func setOnRootChanged(_ handler: (@Sendable (URL) -> Void)?) { onRootChanged = handler }
    /// The app forwards every change to its own channel here.
    public func setChangeForward(_ forward: (@Sendable (DeckMemoryChange) -> Void)?) { hub.setForward(forward) }
    public nonisolated func changes() -> AsyncStream<DeckMemoryChange> { hub.stream() }

    // MARK: Small helpers

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func post(_ area: DeckMemoryChange.Area, _ owner: DeckMemoryOwner? = nil, _ ref: String? = nil) {
        hub.post(.init(area: area, owner: owner, ref: ref, at: now()))
    }
    func missing(_ what: String) -> DeckMemoryError { .init(.notFound, what) }
    /// Keeps the text a file has now in `archive/versions/` before it is replaced.
    /// Returns where the kept copy is (relative to the memory root), or nil when there was nothing to keep.
    @discardableResult
    func keepVersion(of relative: String) -> String? {
        let file = url(relative)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let stem = relative.lowercased().hasSuffix(".md") ? String(relative.dropLast(3)) : relative
        var kept = "archive/versions/" + stem + "." + DeckMemoryFiles.compact(now()) + ".md", counter = 1
        while FileManager.default.fileExists(atPath: url(kept).path) {
            counter += 1; kept = "archive/versions/" + stem + "." + DeckMemoryFiles.compact(now()) + "-\(counter).md"
        }
        try? FileManager.default.createDirectory(at: url(kept).deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: file, to: url(kept)); return kept } catch { return nil }
    }
    /// SQL for "exactly this seat" (or this project's shared space).
    static func ownerClause(_ owner: DeckMemoryOwner) -> (sql: String, args: [DeckMemorySQL]) { ("owner = ?", [.text(owner.key)]) }
    /// SQL for "everything inside this project", whichever seat it belongs to.
    static func projectClause(_ project: String) -> (sql: String, args: [DeckMemorySQL]) {
        let name = DeckMemoryOwner.folderName(project)
        return ("(project = ? OR owner IN (?, ?) OR owner LIKE ? ESCAPE '!')",
                [.text(name), .text("project:" + name), .text("lead:" + name), .text("role:" + likeEscaped(name) + "/%")])
    }
    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_")
    }
    /// SQL for "the rows this owner cares about" on the shared board: Hoot all, a project or its lead the project's, a role seat its own.
    static func scopeClause(_ owner: DeckMemoryOwner) -> (sql: String, args: [DeckMemorySQL])? {
        switch owner {
        case .hoot: return nil
        case .project(let id), .lead(let id): return projectClause(id)
        case .role: return ownerClause(owner)
        }
    }

    // MARK: The search index (one row per note, topic, card, playbook and diary row)

    /// `standing`: 0 current, 1 archived, 2 replaced (superseded or merged). `labels.date` is when it was said or became true.
    func setSearch(kind: DeckMemorySearchKind, ref: String, labels: DeckMemoryLabels, archived: Bool, title: String, body: String, replaced: Bool = false) throws {
        try removeSearch(kind: kind, ref: ref)
        // Text the person marked private is kept where it was said and is never indexed.
        let indexed = DeckMemoryRedaction.withoutPrivate(body)
        let row = try db.run("INSERT INTO search (kind, ref, owner, project, session, agent, archived, title, body, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(kind.rawValue), .text(ref), .text(labels.owner.key), .optional(labels.project), .optional(labels.session), .optional(labels.agent),
             .int(replaced ? 2 : archived ? 1 : 0), .text(title), .text(String(indexed.prefix(20_000))), .date(labels.date)])
        try db.run("INSERT OR REPLACE INTO search_map (kind, ref, row) VALUES (?, ?, ?)", [.text(kind.rawValue), .text(ref), .int(row)])
        if embedder != nil, !embeddingOff {
            try db.run("INSERT OR IGNORE INTO embed_queue (kind, ref) VALUES (?, ?)", [.text(kind.rawValue), .text(ref)])
        }
    }
    func removeSearch(kind: DeckMemorySearchKind, ref: String) throws {
        if let row = try db.first("SELECT row FROM search_map WHERE kind = ? AND ref = ?", [.text(kind.rawValue), .text(ref)]) {
            try db.run("DELETE FROM search WHERE rowid = ?", [.int(row.int(0))])
            try db.run("DELETE FROM search_map WHERE kind = ? AND ref = ?", [.text(kind.rawValue), .text(ref)])
        }
        try db.run("DELETE FROM embeddings WHERE kind = ? AND ref = ?", [.text(kind.rawValue), .text(ref)])
        try db.run("DELETE FROM embed_queue WHERE kind = ? AND ref = ?", [.text(kind.rawValue), .text(ref)])
    }

    // MARK: Seats

    public func owners() async throws -> [DeckMemoryOwnerInfo] {
        var found: [DeckMemoryOwner] = []
        let files = FileManager.default
        func folders(_ relative: String) -> [String] {
            ((try? files.contentsOfDirectory(atPath: url(relative).path)) ?? []).filter { name in
                var isDirectory: ObjCBool = false
                return !name.hasPrefix(".") && files.fileExists(atPath: url(relative + "/" + name).path, isDirectory: &isDirectory) && isDirectory.boolValue
                    && DeckMemoryOwner.folderName(name) == name
            }.sorted()
        }
        if files.fileExists(atPath: url("hoot").path) { found.append(.hoot) }
        for project in folders("projects") {
            found.append(.project(project))
            if files.fileExists(atPath: url("projects/\(project)/lead").path) { found.append(.lead(project)) }
            for role in folders("projects/\(project)/roles") { found.append(.role(project: project, role: role)) }
        }
        for role in folders("roles") { found.append(.role(project: nil, role: role)) }
        return try found.map(info)
    }
    func info(_ owner: DeckMemoryOwner) throws -> DeckMemoryOwnerInfo {
        let cardText = DeckMemoryFiles.read(url(owner.cardPath))
        let heading = cardText.flatMap { DeckMemoryFile(text: $0).headingAndRest.title }
        let fallback: String
        switch owner {
        case .hoot: fallback = "Hoot"
        case .project(let id): fallback = id
        case .role(_, let role): fallback = role
        case .lead(let id): fallback = id + " lead"
        }
        // The seat's title is the one given when the seat was made; a hire's name never replaces it.
        let title = try setting(DeckMemoryKeys.seatTitle, owner: owner) ?? heading ?? fallback
        let key: [DeckMemorySQL] = [.text(owner.key)]
        let notes = try db.first("SELECT COUNT(*) FROM notes WHERE missing = 0 AND archived IS NULL AND owner = ?", key)?.int(0) ?? 0
        let topics = try db.first("SELECT COUNT(*) FROM topics WHERE missing = 0 AND open = 1 AND owner = ?", key)?.int(0) ?? 0
        let diary = try db.first("SELECT COUNT(*) FROM diary WHERE owner = ?", key)?.int(0) ?? 0
        let parent = try setting(DeckMemoryKeys.seatParent, owner: owner).flatMap(DeckMemoryOwner.init(key:))
        return .init(owner: owner, name: title, folder: owner.folder, hasCard: cardText != nil, notes: Int(notes), topics: Int(topics), diary: Int(diary), parent: parent)
    }
    public func ensureOwner(_ owner: DeckMemoryOwner, name: String?, parent: DeckMemoryOwner?) async throws -> DeckMemoryOwnerInfo {
        if let parent {
            guard case .role = owner, parent.isSeat, parent != owner else { throw DeckMemoryError(.invalid, "A helper seat is a role seat that works under another seat.") }
            if try setting(DeckMemoryKeys.seatParent, owner: owner) == nil { try setSetting(parent.key, key: DeckMemoryKeys.seatParent, owner: owner) }
        }
        return try ensureOwnerNow(owner, name: name)
    }
    func ensureOwnerNow(_ owner: DeckMemoryOwner, name: String?) throws -> DeckMemoryOwnerInfo {
        do {
            try FileManager.default.createDirectory(at: url(owner.notesFolder), withIntermediateDirectories: true)
            if owner.isSeat { try FileManager.default.createDirectory(at: url(owner.topicsFolder), withIntermediateDirectories: true) }
            if owner.isSeat, let project = owner.projectID, !FileManager.default.fileExists(atPath: url(DeckMemoryOwner.project(project).cardPath).path) {
                _ = try ensureOwnerNow(.project(project), name: nil)
            }
        } catch let error as DeckMemoryError { throw error }
        catch { throw DeckMemoryError(.io, "The folder for \(owner.key) could not be created: \(error.localizedDescription)") }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !clean.isEmpty, try setting(DeckMemoryKeys.seatTitle, owner: owner) == nil {
            try setSetting(clean, key: DeckMemoryKeys.seatTitle, owner: owner)
        }
        if !FileManager.default.fileExists(atPath: url(owner.cardPath).path) {
            try writeTracked(Self.starterCard(owner, name: clean), to: owner.cardPath, kind: "card", ownerKey: owner.key)
            post(.card, owner)
        }
        if owner.hasPlaybook, !FileManager.default.fileExists(atPath: url(owner.playbookPath).path) {
            try writeTracked(DeckMemoryFiles.playbookText(preface: "", rows: [.init(jobKind: "default")], trailer: ""), to: owner.playbookPath, kind: "playbook", ownerKey: owner.key)
            post(.playbook, owner)
        }
        return try info(owner)
    }
    /// A seat's own card starts nearly empty: everything shared comes from the category template.
    static func starterCard(_ owner: DeckMemoryOwner, name: String) -> String {
        switch owner {
        case .hoot: return "# Hoot\n\n## Top rules\n\n## The person\n\n## Projects (one line each)\n\n## Permissions\n"
        case .project(let id): return "# \(name.isEmpty ? id : name)\n\n## Top rules\n\n## What it is\n\n## Where things are\n"
        case .lead(let id): return "# \(name.isEmpty ? "Lead of " + id : name)\n\n## Top rules\n\n## What this seat is for\n\n## Permissions\n"
        case .role(_, let role): return "# \(name.isEmpty ? role : name)\n\n## Top rules\n\n## What this seat is for\n"
        }
    }

    // MARK: Cards, playbooks, templates and documents share one small table (for search and for noticing outside edits)

    /// Writes a file the index tracks by path, and records what was written so the file watcher stays quiet about it.
    func writeTracked(_ text: String, to relative: String, kind: String, ownerKey: String) throws {
        // Anything that looks like a password, key or token is replaced by a visible marker before it reaches a file.
        let safe = DeckMemoryRedaction.redacted(text)
        try DeckMemoryFiles.write(safe, to: url(relative))
        try trackFile(relative, kind: kind, ownerKey: ownerKey, text: safe)
    }
    func trackFile(_ relative: String, kind: String, ownerKey: String, text: String) throws {
        let info = DeckMemoryFiles.info(url(relative)) ?? (now().timeIntervalSince1970, text.utf8.count)
        try db.run("INSERT INTO files (path, kind, owner, mtime, bytes, hash, missing) VALUES (?, ?, ?, ?, ?, ?, 0) ON CONFLICT(path) DO UPDATE SET kind = excluded.kind, owner = excluded.owner, mtime = excluded.mtime, bytes = excluded.bytes, hash = excluded.hash, missing = 0",
            [.text(relative), .text(kind), .text(ownerKey), .real(info.mtime), .int(Int64(info.bytes)), .text(DeckMemoryFiles.hash(text))])
        guard let owner = DeckMemoryOwner(key: ownerKey) else { return }
        let labels = DeckMemoryLabels(owner: owner, project: owner.projectID, date: Date(timeIntervalSince1970: info.mtime), type: kind)
        if kind == "card" { try setSearch(kind: .card, ref: owner.key, labels: labels, archived: false, title: "Card", body: text) }
        if kind == "playbook" { try setSearch(kind: .playbook, ref: owner.key, labels: labels, archived: false, title: "Playbook", body: text) }
    }

    // MARK: Templates (one per category)

    /// The card text the app ships for a category, by version. Version 1 is what the first installs wrote on
    /// 11 Oct 2026; version 2 adds the line that says how the memory tools are called. An earlier version is kept
    /// here word for word, because a card file that still equals it was never touched by the person and may follow the app.
    static let shippedCardVersion = 3
    static func shippedCard(_ category: DeckMemoryCategory, version: Int = shippedCardVersion) -> String {
        let rules = "## Top rules\n- Memory lives in the app, not in this chat. Trust your card, your topics, your notes and the board over your own recollection.\n- Exact facts (which build is installed, did it ship) are checked at the source, never from memory.\n"
        // Since version 2: the tools are not in a session's tool list by name, so the card says how to reach them.
        let call = version >= 2 ? "- To use a memory tool: look it up with tools_describe (it shows the tool's arguments), then call it with tools_run.\n" : ""
        // Since version 3: one search finds one thing best.
        let several = version >= 3 ? "- When a question needs several facts, search once for each fact.\n" : ""
        let memory = "## How to use memory\n" + call + several + "- Search before you assume: memory.search covers notes, topics, cards and the diary of every message.\n- Keep one \"where we are\" topic per open piece of work (memory.topic.update), so a clean desk can carry on.\n- Write a short note (memory.note.add) for a decision, a preference, a correction, a result, an open item or a lesson. A newer note replaces an older one; nothing is deleted.\n"
        let report = "Done or not · the result in three lines · the proof · what you need. Long output stays in the session.\n"
        switch category {
        case .orchestrator:
            return "# Orchestrator\n\nYou are the orchestrator. You talk with the person, give project leads their goals and read their reports. You assign agents yourself only in projects that have no lead.\n\n" + rules + "\n" + memory + "- Follow the playbook whenever you start or steer a session.\n\n## What you expect back from leads and agents\n" + report
        case .lead:
            return "# Lead\n\nYou are the lead of a project. The orchestrator gives you goals; you run this project's agents and report back. The seat's memory was built by whoever held it before you and stays for whoever comes next.\n\n" + rules + "\n" + memory + "- Follow the playbook whenever you start or steer a session.\n\n## How you report\n" + report
        case .agent:
            return "# Agent\n\nYou hold a role (a seat). The seat's memory was built by whoever held it before you and stays for whoever comes next. Remember the why; read the files for the what.\n\n" + rules + "\n" + memory + "\n## How you report\n" + report
        }
    }
    /// Every card text the app shipped before the current one.
    static func earlierShippedCards(_ category: DeckMemoryCategory) -> [String] {
        (1..<shippedCardVersion).map { shippedCard(category, version: $0) }
    }
    static func defaultTemplate(_ category: DeckMemoryCategory) -> DeckMemoryTemplate {
        let checklist = "# What the helper looks for\n\nAfter a turn the helper reads only the new part of the diary and writes short dated notes. When unsure, it keeps the note.\n\n- A decision the person made, and why.\n- A preference or a standing rule the person stated.\n- A correction: something that was done wrong and what is right.\n- A result: what was finished, with where the proof is.\n- An open item: something asked for and not done yet.\n- A lesson: something that will matter the next time this kind of job comes up.\n"
        return .init(category: category, card: shippedCard(category), checklist: checklist,
                     parts: category == .agent ? Set(DeckMemoryPart.allCases).subtracting([.playbook]) : Set(DeckMemoryPart.allCases))
    }
    static func templateSettingsText(_ template: DeckMemoryTemplate) -> String {
        let parts = DeckMemoryPart.allCases.filter(template.parts.contains).map(\.rawValue).joined(separator: ", ")
        return "# Settings for \(template.category.everyone)\n\nThese apply to every member of this category, now and for every future hire. Change the value after the colon.\n\n- parts: \(parts)\n- helper ai: \(template.helperAI)\n- helper model: \(template.helperModel)\n- card limit: \(template.cardLimit)\n- hands per seat: \(template.handsPerSeat)\n- hands per project: \(template.handsPerProject)\n"
    }
    static func applySettings(_ text: String, to template: inout DeckMemoryTemplate) {
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "parts":
                let named = value.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { DeckMemoryPart(rawValue: $0.lowercased()) }
                template.parts = Set(named)
            // "refresh at" (the removed planned refresh) is skipped like any unknown line.
            case "helper ai": if ["claude", "codex", "gemini"].contains(value.lowercased()) { template.helperAI = value.lowercased() }
            case "helper model": template.helperModel = value
            case "card limit": if let number = Int(value), number >= 200, number <= 200_000 { template.cardLimit = number }
            case "hands per seat": if let number = Int(value), number >= 1, number <= 50 { template.handsPerSeat = number }
            case "hands per project": if let number = Int(value), number >= 1, number <= 500 { template.handsPerProject = number }
            default: break
            }
        }
    }
    func ensureTemplateFiles(_ category: DeckMemoryCategory) throws {
        let fresh = Self.defaultTemplate(category), folder = category.templateFolder
        // A card that is still, byte for byte, the text an EARLIER version of the app wrote was never edited by the
        // person: it follows the app to the new shipped text (the old text is kept in archive/versions/). A card the
        // person changed in any way is theirs and is left exactly as it is.
        let cardPath = folder + "/card.md"
        if let current = DeckMemoryFiles.read(url(cardPath)), current != fresh.card, Self.earlierShippedCards(category).contains(current) {
            keepVersion(of: cardPath)
            try writeTracked(fresh.card, to: cardPath, kind: "template", ownerKey: "template:" + category.rawValue)
            post(.templates, nil, category.rawValue)
        }
        for (name, text) in [("card.md", fresh.card), ("checklist.md", fresh.checklist), ("settings.md", Self.templateSettingsText(fresh))]
        where !FileManager.default.fileExists(atPath: url(folder + "/" + name).path) {
            try writeTracked(text, to: folder + "/" + name, kind: "template", ownerKey: "template:" + category.rawValue)
        }
        // 28 Oct 2026 (Asad): the planned refresh is gone. A settings file that still names it ("refresh at", or
        // "refresh" among the parts) is written once more without it, every other value kept, so no line in it
        // points at a removed feature. The earlier text is kept in archive/versions/.
        let settingsPath = folder + "/settings.md"
        if let current = DeckMemoryFiles.read(url(settingsPath)), Self.namesRemovedRefresh(current) {
            keepVersion(of: settingsPath)
            try writeTracked(Self.templateSettingsText(templateNow(category)), to: settingsPath, kind: "template", ownerKey: "template:" + category.rawValue)
        }
    }
    /// A settings file written before 28 Oct 2026 that still names the removed planned refresh.
    static func namesRemovedRefresh(_ text: String) -> Bool {
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "refresh at" || key == "refresh" { return true }
            let value = line[line.index(after: colon)...].lowercased()
            if key == "parts", value.split(whereSeparator: { $0 == "," || $0 == " " }).contains("refresh") { return true }
        }
        return false
    }
    public func template(_ category: DeckMemoryCategory) async throws -> DeckMemoryTemplate { templateNow(category) }
    func templateNow(_ category: DeckMemoryCategory) -> DeckMemoryTemplate { Self.readTemplate(category, root: root) }
    static func readTemplate(_ category: DeckMemoryCategory, root: URL) -> DeckMemoryTemplate {
        var template = Self.defaultTemplate(category)
        let folder = category.templateFolder
        if let card = DeckMemoryFiles.read(root.appendingPathComponent(folder + "/card.md")) { template.card = card }
        if let checklist = DeckMemoryFiles.read(root.appendingPathComponent(folder + "/checklist.md")) { template.checklist = checklist }
        if let settings = DeckMemoryFiles.read(root.appendingPathComponent(folder + "/settings.md")) { Self.applySettings(settings, to: &template) }
        template.updatedAt = ["card.md", "checklist.md", "settings.md"].compactMap { DeckMemoryFiles.info(root.appendingPathComponent(folder + "/" + $0))?.mtime }.max().map(Date.init(timeIntervalSince1970:))
        return template
    }
    public func saveTemplate(_ template: DeckMemoryTemplate) async throws -> DeckMemoryTemplate { try saveTemplateNow(template) }
    func saveTemplateNow(_ template: DeckMemoryTemplate) throws -> DeckMemoryTemplate {
        guard template.cardLimit >= 200, template.cardLimit <= 200_000 else { throw DeckMemoryError(.invalid, "A card's size cap must be between 200 and 200,000 characters.") }
        guard ["claude", "codex", "gemini"].contains(template.helperAI) else { throw DeckMemoryError(.invalid, "The helper's AI must be claude, codex or gemini.") }
        guard template.handsPerSeat >= 1, template.handsPerSeat <= 50, template.handsPerProject >= 1, template.handsPerProject <= 500 else {
            throw DeckMemoryError(.invalid, "The number of hands must be at least 1 (up to 50 per seat, 500 per project).")
        }
        guard template.handsPerProject >= template.handsPerSeat else { throw DeckMemoryError(.invalid, "A project cannot allow fewer hands than one seat does.") }
        let folder = template.category.templateFolder
        var changed = false
        for (name, text) in [("card.md", template.card), ("checklist.md", template.checklist), ("settings.md", Self.templateSettingsText(template))] {
            let relative = folder + "/" + name
            if name == "settings.md", let current = DeckMemoryFiles.read(url(relative)) {
                // Settings are compared by meaning, so hand-written wording in that file is kept when nothing changed.
                var parsed = Self.defaultTemplate(template.category); Self.applySettings(current, to: &parsed)
                if parsed.parts == template.parts, parsed.helperAI == template.helperAI,
                   parsed.helperModel == template.helperModel, parsed.cardLimit == template.cardLimit,
                   parsed.handsPerSeat == template.handsPerSeat, parsed.handsPerProject == template.handsPerProject { continue }
            } else if DeckMemoryFiles.read(url(relative)) == text { continue }
            keepVersion(of: relative)
            try writeTracked(text, to: relative, kind: "template", ownerKey: "template:" + template.category.rawValue)
            changed = true
        }
        if changed { post(.templates, nil, template.category.rawValue) }
        return templateNow(template.category)
    }

    // MARK: Card

    public func cardLimit(_ owner: DeckMemoryOwner) async throws -> Int { try limit(owner) }
    func limit(_ owner: DeckMemoryOwner) throws -> Int {
        if let category = owner.category { return templateNow(category).cardLimit }
        if let own = try setting(DeckMemoryKeys.cardLimit, owner: owner).flatMap(Int.init), own > 0 { return own }
        return DeckMemoryCard.defaultLimit
    }
    public func setCardLimit(_ limit: Int, for owner: DeckMemoryOwner) async throws {
        guard limit >= 200, limit <= 200_000 else { throw DeckMemoryError(.invalid, "A card's size cap must be between 200 and 200,000 characters.") }
        if let category = owner.category {
            // Nothing is configured per individual: the cap belongs to the category.
            var template = templateNow(category); template.cardLimit = limit
            _ = try saveTemplateNow(template)
        } else {
            try setSetting(String(limit), key: DeckMemoryKeys.cardLimit, owner: owner)
            post(.card, owner)
        }
    }
    public func assembledCard(_ owner: DeckMemoryOwner) async throws -> DeckMemoryAssembledCard { try assembledNow(owner) }
    func assembledNow(_ owner: DeckMemoryOwner) throws -> DeckMemoryAssembledCard {
        let shared = owner.category.map { templateNow($0).card } ?? ""
        return DeckMemoryAssembledCard(owner: owner, shared: shared, own: DeckMemoryFiles.read(url(owner.cardPath)) ?? "", limit: try limit(owner))
    }
    public func card(_ owner: DeckMemoryOwner) async throws -> DeckMemoryCard { try cardNow(owner) }
    func cardNow(_ owner: DeckMemoryOwner) throws -> DeckMemoryCard {
        let file = url(owner.cardPath), text = DeckMemoryFiles.read(file)
        let modified = text == nil ? nil : DeckMemoryFiles.info(file).map { Date(timeIntervalSince1970: $0.mtime) }
        let assembled = try assembledNow(owner)
        return DeckMemoryCard(owner: owner, text: text ?? "", path: owner.cardPath, limit: assembled.limit, updatedAt: modified,
                              sharedCharacters: max(0, assembled.characters - (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count))
    }
    public func saveCard(_ owner: DeckMemoryOwner, text: String) async throws -> DeckMemoryCard {
        if DeckMemoryFiles.read(url(owner.cardPath)) != DeckMemoryRedaction.redacted(text) {
            keepVersion(of: owner.cardPath)
            // The whole text is saved even when it is over the cap; the cap is reported, never applied by cutting.
            try writeTracked(text, to: owner.cardPath, kind: "card", ownerKey: owner.key)
            post(.card, owner)
            kickEmbedding()
        }
        return try cardNow(owner)
    }

    // MARK: Playbook

    public func playbook(_ owner: DeckMemoryOwner) async throws -> DeckMemoryPlaybook { try playbookNow(owner) }
    func playbookNow(_ owner: DeckMemoryOwner) throws -> DeckMemoryPlaybook {
        guard owner.hasPlaybook else { throw DeckMemoryError(.invalid, "Only the orchestrator and project leads keep a playbook.") }
        let file = url(owner.playbookPath)
        guard let text = DeckMemoryFiles.read(file) else { return .init(owner: owner, rows: [], path: owner.playbookPath, updatedAt: nil) }
        let parsed = DeckMemoryFiles.parsePlaybook(text)
        return .init(owner: owner, rows: parsed.rows, preface: parsed.preface, path: owner.playbookPath,
                     updatedAt: DeckMemoryFiles.info(file).map { Date(timeIntervalSince1970: $0.mtime) })
    }
    public func savePlaybook(_ owner: DeckMemoryOwner, rows: [DeckMemoryPlaybookRow], preface: String?) async throws -> DeckMemoryPlaybook {
        guard owner.hasPlaybook else { throw DeckMemoryError(.invalid, "Only the orchestrator and project leads keep a playbook.") }
        var seen = Set<String>()
        for row in rows {
            guard !row.jobKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeckMemoryError(.invalid, "Every playbook row needs a job kind.") }
            guard seen.insert(row.id).inserted else { throw DeckMemoryError(.invalid, "The playbook has two rows for \"\(row.jobKind)\".") }
        }
        let current = DeckMemoryFiles.read(url(owner.playbookPath)), parsed = current.map(DeckMemoryFiles.parsePlaybook)
        let text = DeckMemoryFiles.playbookText(preface: preface ?? parsed?.preface ?? "", rows: rows, trailer: parsed?.trailer ?? "")
        if current != text {
            keepVersion(of: owner.playbookPath)
            try writeTracked(text, to: owner.playbookPath, kind: "playbook", ownerKey: owner.key)
            post(.playbook, owner)
        }
        return try playbookNow(owner)
    }
    public func playbookRow(_ owner: DeckMemoryOwner, job: String) async throws -> DeckMemoryPlaybookRow? {
        let wanted = job.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func specific(_ book: DeckMemoryPlaybook) -> DeckMemoryPlaybookRow? {
            guard let row = book.row(for: job) else { return nil }
            return DeckMemoryPlaybookRow.fallbackKinds.contains(row.jobKind.lowercased()) && row.jobKind.lowercased() != wanted ? nil : row
        }
        if owner.hasPlaybook {
            let own = try playbookNow(owner)
            if let row = specific(own) { return row }
            if owner != .hoot, let row = specific(try playbookNow(.hoot)) { return row }
            if let row = own.row(for: job) { return row }
        }
        return owner == .hoot ? nil : try playbookNow(.hoot).row(for: job)
    }

    // MARK: Documents

    static func documentName(_ name: String) throws -> String {
        let clean = DeckMemoryOwner.slug(name)
        guard clean != "unnamed", !["card", "playbook"].contains(clean) else { throw DeckMemoryError(.invalid, "\"\(name)\" is not a usable file name here.") }
        return clean
    }
    public func document(_ owner: DeckMemoryOwner, name: String) async throws -> String? {
        DeckMemoryFiles.read(url(owner.folder + "/" + (try Self.documentName(name)) + ".md"))
    }
    public func saveDocument(_ owner: DeckMemoryOwner, name: String, text: String) async throws {
        let clean = try Self.documentName(name), relative = owner.folder + "/" + clean + ".md"
        guard DeckMemoryFiles.read(url(relative)) != text else { return }
        keepVersion(of: relative)
        try writeTracked(text, to: relative, kind: "document", ownerKey: owner.key)
        post(.documents, owner, clean)
    }

    // MARK: Settings

    func setting(_ key: String, owner: DeckMemoryOwner?) throws -> String? {
        try db.first("SELECT value FROM settings WHERE owner = ? AND key = ?", [.text(owner?.key ?? ""), .text(key)])?.string(0)
    }
    func setSetting(_ value: String?, key: String, owner: DeckMemoryOwner?) throws {
        if let value {
            try db.run("INSERT INTO settings (owner, key, value, updated) VALUES (?, ?, ?, ?) ON CONFLICT(owner, key) DO UPDATE SET value = excluded.value, updated = excluded.updated",
                       [.text(owner?.key ?? ""), .text(key), .text(value), .date(now())])
        } else {
            try db.run("DELETE FROM settings WHERE owner = ? AND key = ?", [.text(owner?.key ?? ""), .text(key)])
        }
    }
    public func value(_ key: String, owner: DeckMemoryOwner?) async throws -> String? { try setting(key, owner: owner) }
    public func setValue(_ value: String?, key: String, owner: DeckMemoryOwner?) async throws {
        guard try setting(key, owner: owner) != value else { return }
        try setSetting(value, key: key, owner: owner)
        post(.settings, owner, key)
    }

    // MARK: Questions for you

    private static let questionColumns = "id, owner, text, context, refs, asked, answer, answered, dismissed"
    private func question(_ row: DeckMemoryRow) -> DeckMemoryQuestion {
        let refs = (try? JSONDecoder().decode([String].self, from: Data(row.text(4).utf8))) ?? []
        return .init(id: row.int(0), owner: DeckMemoryOwner(key: row.text(1)) ?? .hoot, text: row.text(2), context: row.text(3), refs: refs,
                     askedAt: row.date(5) ?? now(), answer: row.string(6), answeredAt: row.date(7), dismissedAt: row.date(8))
    }
    /// Lower-case with spaces squeezed, so the same question worded the same way is recognised.
    private static func sameQuestion(_ a: String, _ b: String) -> Bool {
        func plain(_ text: String) -> String { text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") }
        return plain(a) == plain(b)
    }
    public func addQuestion(owner: DeckMemoryOwner, text: String, context: String, refs: [String]) async throws -> DeckMemoryQuestion {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw DeckMemoryError(.invalid, "A question needs some text.") }
        // The same open question is asked once, and a question the person waved away is never raised again:
        // the one that is already there comes back and nothing new is made.
        let standing = try db.rows("SELECT \(Self.questionColumns) FROM questions WHERE owner = ? AND (dismissed IS NOT NULL OR answered IS NULL)", [.text(owner.key)])
        if let same = standing.first(where: { Self.sameQuestion($0.text(2), clean) }) { return question(same) }
        let encoded = String(decoding: (try? JSONEncoder().encode(refs)) ?? Data("[]".utf8), as: UTF8.self)
        let id = try db.run("INSERT INTO questions (owner, text, context, refs, asked) VALUES (?, ?, ?, ?, ?)",
                            [.text(owner.key), .text(clean), .text(context), .text(encoded), .date(now())])
        post(.questions, owner, String(id))
        return question(try db.first("SELECT \(Self.questionColumns) FROM questions WHERE id = ?", [.int(id)])!)
    }
    public func questions(owner: DeckMemoryOwner?, openOnly: Bool) async throws -> [DeckMemoryQuestion] {
        var clauses: [String] = [], args: [DeckMemorySQL] = []
        if let owner { clauses.append("owner = ?"); args.append(.text(owner.key)) }
        if openOnly { clauses.append("answered IS NULL AND dismissed IS NULL") }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        // Open first, then answered, then dismissed; newest first inside each.
        return try db.rows("SELECT \(Self.questionColumns) FROM questions\(filter) ORDER BY dismissed IS NOT NULL, answered IS NOT NULL, asked DESC LIMIT 500", args).map(question)
    }
    public func answerQuestion(id: Int64, answer: String) async throws -> DeckMemoryQuestion {
        guard try db.first("SELECT 1 FROM questions WHERE id = ?", [.int(id)]) != nil else { throw missing("That question is not on the list any more.") }
        // Answering a question the person had waved away brings it back off the Dismissed list.
        try db.run("UPDATE questions SET answer = ?, answered = ?, dismissed = NULL WHERE id = ?", [.text(answer), .date(now()), .int(id)])
        let saved = question(try db.first("SELECT \(Self.questionColumns) FROM questions WHERE id = ?", [.int(id)])!)
        post(.questions, saved.owner, String(id))
        return saved
    }
    public func dismissQuestion(id: Int64) async throws -> DeckMemoryQuestion { try setDismissed(id, true) }
    public func reopenQuestion(id: Int64) async throws -> DeckMemoryQuestion { try setDismissed(id, false) }
    private func setDismissed(_ id: Int64, _ dismissed: Bool) throws -> DeckMemoryQuestion {
        guard let row = try db.first("SELECT \(Self.questionColumns) FROM questions WHERE id = ?", [.int(id)]) else { throw missing("That question is not on the list any more.") }
        let before = question(row)
        guard before.isDismissed != dismissed else { return before }
        if dismissed { try db.run("UPDATE questions SET dismissed = ? WHERE id = ?", [.date(now()), .int(id)]) }
        else { try db.run("UPDATE questions SET dismissed = NULL, answer = NULL, answered = NULL WHERE id = ?", [.int(id)]) }
        let saved = question(try db.first("SELECT \(Self.questionColumns) FROM questions WHERE id = ?", [.int(id)])!)
        post(.questions, saved.owner, String(id))
        return saved
    }

    // MARK: START-HERE and pointers

    public func writeStartHere() async throws { try writeStartHereFiles() }
    func writeStartHereFiles() throws {
        var wanted: [(String, String)] = [("START-HERE.md", DeckMemoryFiles.startHere())]
        wanted += DeckMemoryFiles.pointers.map { ($0.file, DeckMemoryFiles.pointer($0.app)) }
        for (name, text) in wanted {
            let file = url(name)
            if let current = DeckMemoryFiles.read(file) {
                // A file the person took over (our marker removed) is left alone.
                guard current.contains(DeckMemoryFiles.generatedMarker), current != text else { continue }
            }
            try DeckMemoryFiles.write(text, to: file)
        }
    }
}
