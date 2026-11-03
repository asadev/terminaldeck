import Foundation
import TerminalDeckNativeCore

// Handoffs: Markdown documents kept with a topic. Files are the truth, the database is their index.
extension DeckMemoryStore {
    static let handoffColumns = "id, path, owner, topic, title, project, session, agent, hand, job, author, date, updated, archived"

    /// How a handoff is named in the search index: a topic hit of its seat and topic, marked as a handoff.
    static func handoffRef(ownerKey: String, topic: String?, id: String) -> String { ownerKey + "/" + (topic ?? "") + "#handoff:" + id }
    static func handoffFolder(_ owner: DeckMemoryOwner, topic: String?) -> String {
        topic.map { owner.topicsFolder + "/" + $0 + "/handoffs" } ?? owner.folder + "/handoffs"
    }
    func handoffRow(_ id: String) throws -> DeckMemoryRow? {
        try db.first("SELECT \(Self.handoffColumns) FROM handoffs WHERE id = ? AND missing = 0", [.text(id)])
    }
    func handoff(_ row: DeckMemoryRow) -> DeckMemoryHandoff {
        let owner = DeckMemoryOwner(key: row.text(2)) ?? .hoot, path = row.text(1), created = row.date(11) ?? now()
        let markdown = DeckMemoryFiles.read(url(path)).map { DeckMemoryFile(text: $0).body } ?? ""
        return .init(id: row.text(0), owner: owner, topic: row.string(3), title: row.text(4), markdown: markdown,
                     labels: .init(owner: owner, project: row.string(5), session: row.string(6), agent: row.string(7), date: created, type: "handoff",
                                   hand: row.optionalInt(8), job: row.string(9)),
                     path: path, author: row.string(10).flatMap(DeckMemoryAuthor.init(rawValue:)), createdAt: created,
                     updatedAt: row.date(12) ?? created, archivedAt: row.date(13))
    }

    /// Reads one handoff file and brings its index row and search row in line. A file dropped in by hand gets its labels.
    @discardableResult
    func indexHandoff(path: String, pathOwner: DeckMemoryOwner, topic pathTopic: String?, archivedByPath: Bool, text given: String? = nil) throws -> (id: String, changed: Bool)? {
        guard var text = given ?? DeckMemoryFiles.read(url(path)), var info = DeckMemoryFiles.info(url(path)) else { return nil }
        var file = DeckMemoryFile(text: text)
        let modified = Date(timeIntervalSince1970: info.mtime)
        var id = file.value("id") ?? ""
        if !id.isEmpty, let other = try db.first("SELECT path FROM handoffs WHERE id = ? AND missing = 0", [.text(id)])?.text(0), other != path,
           FileManager.default.fileExists(atPath: url(other).path) { id = "" }
        if id.isEmpty {
            id = "h-" + DeckMemoryFiles.day(modified).replacingOccurrences(of: "-", with: "") + "-" + DeckMemoryFiles.shortID()
            file.set("id", id); file.set("type", "handoff"); file.set("seat", pathOwner.key); file.set("category", pathOwner.category?.rawValue)
            file.set("project", pathOwner.projectID); file.set("topic", pathTopic)
            if file.value("date") == nil { file.set("date", DeckMemoryFiles.stamp(modified)) }
            text = file.text
            try DeckMemoryFiles.write(text, to: url(path))
            info = DeckMemoryFiles.info(url(path)) ?? info
        }
        let hash = DeckMemoryFiles.hash(text)
        if let known = try db.first("SELECT path, hash, missing, archived FROM handoffs WHERE id = ?", [.text(id)]),
           known.text(0) == path, known.text(1) == hash, known.int(2) == 0, known.isNull(3) != archivedByPath {
            try db.run("UPDATE handoffs SET mtime = ?, bytes = ? WHERE id = ?", [.real(info.mtime), .int(Int64(info.bytes)), .text(id)])
            return (id, false)
        }
        let owner = DeckMemoryOwner(key: file.value("seat") ?? "") ?? pathOwner
        let topic = file.value("topic") ?? pathTopic
        let title = file.value("title") ?? file.headingAndRest.title ?? Self.stem(path)
        let date = DeckMemoryFiles.date(file.value("date")) ?? modified
        let archived: Date? = archivedByPath ? (DeckMemoryFiles.date(file.value("archived")) ?? modified) : nil
        let origin: String? = archivedByPath ? (path.hasPrefix("archive/") ? String(path.dropFirst("archive/".count)) : path) : nil
        try db.run("UPDATE handoffs SET missing = 1, path = path || '#replaced-' || id WHERE path = ? AND id != ?", [.text(path), .text(id)])
        try db.run("""
            INSERT INTO handoffs (id, path, owner, topic, title, project, session, agent, hand, job, author, date, updated, archived, archive_reason, origin_path, mtime, bytes, hash, missing)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET path = excluded.path, owner = excluded.owner, topic = excluded.topic, title = excluded.title, project = excluded.project,
                session = excluded.session, agent = excluded.agent, hand = excluded.hand, job = excluded.job, author = excluded.author, date = excluded.date,
                updated = excluded.updated, archived = excluded.archived, archive_reason = excluded.archive_reason, origin_path = excluded.origin_path,
                mtime = excluded.mtime, bytes = excluded.bytes, hash = excluded.hash, missing = 0
            """, [.text(id), .text(path), .text(owner.key), .optional(topic), .text(title), .optional(file.value("project") ?? owner.projectID),
                  .optional(file.value("session")), .optional(file.value("hire")), .optional(file.value("hand").flatMap(Int.init)), .optional(file.value("job")),
                  .optional(file.value("author").flatMap(DeckMemoryAuthor.init(rawValue:))?.rawValue), .date(date), .date(modified),
                  .optional(archived), .optional(archivedByPath ? (file.value("archive_reason") ?? "archived") : nil), .optional(origin),
                  .real(info.mtime), .int(Int64(info.bytes)), .text(hash)])
        let labels = DeckMemoryLabels(owner: owner, project: file.value("project") ?? owner.projectID, session: file.value("session"),
                                      agent: file.value("hire"), date: date, type: "handoff", hand: file.value("hand").flatMap(Int.init), job: file.value("job"))
        try setSearch(kind: .topic, ref: Self.handoffRef(ownerKey: owner.key, topic: topic, id: id), labels: labels, archived: archivedByPath,
                      title: "Handoff: " + title, body: file.body)
        return (id, true)
    }

    public func saveHandoff(_ draft: DeckMemoryHandoffDraft) async throws -> DeckMemoryHandoff {
        let owner = draft.stamp.owner
        let markdown = DeckMemoryRedaction.redacted(draft.markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !markdown.isEmpty else { throw DeckMemoryError(.invalid, "A handoff needs its text.") }
        var title = DeckMemoryRedaction.redacted(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
        if title.isEmpty { title = DeckMemoryFile(body: markdown).headingAndRest.title ?? "Handoff" }
        // The topic by its id, or by its title; a topic that does not exist yet still gets its folder.
        var topic: String?
        if let named = draft.topic?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            let wanted = DeckMemoryOwner.slug(named)
            topic = try db.first("SELECT id FROM topics WHERE owner = ? AND missing = 0 AND (id = ? OR id = ? OR lower(title) = lower(?)) LIMIT 1",
                                 [.text(owner.key), .text(named), .text(wanted), .text(named)])?.text(0) ?? wanted
        }
        let date = now(), id = "h-" + DeckMemoryFiles.day(date).replacingOccurrences(of: "-", with: "") + "-" + DeckMemoryFiles.shortID()
        let path = Self.handoffFolder(owner, topic: topic) + "/" + DeckMemoryFiles.compact(date) + "-" + String(id.suffix(6)) + ".md"
        var file = DeckMemoryFile(body: markdown + "\n")
        file.set("id", id); file.set("type", "handoff"); file.set("title", title); file.set("topic", topic)
        file.set("seat", owner.key); file.set("category", owner.category?.rawValue); file.set("project", draft.stamp.project)
        file.set("session", draft.stamp.session); file.set("hand", draft.stamp.hand.map(String.init)); file.set("job", draft.stamp.job)
        file.set("hire", draft.stamp.agent); file.set("author", (draft.author ?? DeckMemoryAuthor.of(owner))?.rawValue)
        file.set("date", DeckMemoryFiles.stamp(date))
        try DeckMemoryFiles.write(file.text, to: url(path))
        try indexHandoff(path: path, pathOwner: owner, topic: topic, archivedByPath: false, text: file.text)
        post(.topics, owner, "handoff:" + id)
        kickEmbedding()
        guard let row = try handoffRow(id) else { throw DeckMemoryError(.io, "The handoff was written but could not be read back.") }
        return handoff(row)
    }

    public func updateHandoff(id: String, title: String?, markdown: String?) async throws -> DeckMemoryHandoff {
        guard let row = try handoffRow(id), let text = DeckMemoryFiles.read(url(row.text(1))) else { throw missing("That handoff is not in memory any more.") }
        var file = DeckMemoryFile(text: text)
        if let title { let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "); if !clean.isEmpty { file.set("title", DeckMemoryRedaction.redacted(clean)) } }
        if let markdown {
            let clean = DeckMemoryRedaction.redacted(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !clean.isEmpty else { throw DeckMemoryError(.invalid, "A handoff needs its text.") }
            file.body = clean + "\n"
        }
        guard file.text != text else { return handoff(row) }
        // The person's hand has been on it now.
        file.set("author", DeckMemoryAuthor.person.rawValue)
        keepVersion(of: row.text(1))
        try DeckMemoryFiles.write(file.text, to: url(row.text(1)))
        let owner = DeckMemoryOwner(key: row.text(2)) ?? .hoot
        try indexHandoff(path: row.text(1), pathOwner: owner, topic: row.string(3), archivedByPath: !row.isNull(13), text: file.text)
        post(.topics, owner, "handoff:" + id); kickEmbedding()
        return handoff(try handoffRow(id)!)
    }

    public func handoff(id: String) async throws -> DeckMemoryHandoff? { try handoffRow(id).map(handoff) }

    public func handoffs(_ owner: DeckMemoryOwner, topic: String?, includeArchived: Bool) async throws -> [DeckMemoryHandoff] {
        var sql = "SELECT \(Self.handoffColumns) FROM handoffs WHERE owner = ? AND missing = 0", args: [DeckMemorySQL] = [.text(owner.key)]
        if let topic, !topic.isEmpty {
            sql += " AND (topic = ? OR topic = ?)"; args += [.text(topic), .text(DeckMemoryOwner.slug(topic))]
        } else { sql += " AND topic IS NULL" }
        if !includeArchived { sql += " AND archived IS NULL" }
        return try db.rows(sql + " ORDER BY date DESC, id DESC LIMIT 500", args).map(handoff)
    }
    public func allHandoffs(_ owner: DeckMemoryOwner, includeArchived: Bool) async throws -> [DeckMemoryHandoff] {
        try db.rows("SELECT \(Self.handoffColumns) FROM handoffs WHERE owner = ? AND missing = 0\(includeArchived ? "" : " AND archived IS NULL") ORDER BY date DESC, id DESC LIMIT 1000",
                    [.text(owner.key)]).map(handoff)
    }

    public func archiveHandoff(id: String, reason: String) async throws -> DeckMemoryHandoff { try moveHandoff(id, archive: true, reason: reason) }
    public func restoreHandoff(id: String) async throws -> DeckMemoryHandoff { try moveHandoff(id, archive: false, reason: "") }
    /// Into `archive/` at the same path, or back out of it. Nothing is removed.
    private func moveHandoff(_ id: String, archive: Bool, reason: String) throws -> DeckMemoryHandoff {
        guard let row = try handoffRow(id) else { throw missing("That handoff is not in memory any more.") }
        guard row.isNull(13) == archive else { return handoff(row) }
        let path = row.text(1), owner = DeckMemoryOwner(key: row.text(2)) ?? .hoot
        guard var file = DeckMemoryFiles.read(url(path)).map(DeckMemoryFile.init(text:)) else { throw missing("That handoff's file is gone from the memory folder.") }
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted: String
        if archive {
            file.set("archived", DeckMemoryFiles.stamp(now())); file.set("archive_reason", clean.isEmpty ? "archived" : clean)
            wanted = "archive/" + path
        } else {
            file.set("archived", nil); file.set("archive_reason", nil)
            wanted = try db.first("SELECT origin_path FROM handoffs WHERE id = ?", [.text(id)])?.string(0) ?? (path.hasPrefix("archive/") ? String(path.dropFirst("archive/".count)) : path)
        }
        var target = wanted, counter = 1
        while FileManager.default.fileExists(atPath: url(target).path) { counter += 1; target = String(wanted.dropLast(3)) + "-\(counter).md" }
        try DeckMemoryFiles.write(file.text, to: url(path))
        do {
            try FileManager.default.createDirectory(at: url(target).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url(path), to: url(target))
        } catch { throw DeckMemoryError(.io, "The handoff could not be moved: \(error.localizedDescription)") }
        try indexHandoff(path: target, pathOwner: owner, topic: row.string(3), archivedByPath: archive, text: file.text)
        if archive { try db.run("UPDATE handoffs SET origin_path = ? WHERE id = ?", [.text(path), .text(id)]) }
        post(.topics, owner, "handoff:" + id)
        return handoff(try handoffRow(id)!)
    }
}
