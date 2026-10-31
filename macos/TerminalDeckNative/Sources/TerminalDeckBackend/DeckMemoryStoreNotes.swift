import Foundation
import TerminalDeckNativeCore

// Notes and topics: Markdown files are the truth, the database is their index.
extension DeckMemoryStore {
    static let noteColumns = "id, path, title, type, owner, project, session, agent, date, source, supersedes, superseded_by, archived, archive_reason, origin_path, updated, hand, job, valid_from, valid_until, diary_first, diary_last, author, hash"

    /// Reuses parsed note text until the indexed content hash changes.
    func note(_ row: DeckMemoryRow) -> DeckMemoryNote {
        let id = row.text(0), path = row.text(1), owner = DeckMemoryOwner(key: row.text(4)) ?? .hoot
        var body = "", links: [String] = [], short: String?, shortBy: DeckMemoryShortTitle.Maker?
        if noteFiles[id]?.hash != row.text(23), let text = DeckMemoryFiles.read(url(path)) {
            noteFiles[id] = (row.text(23), DeckMemoryFile(text: text))
        }
        if let file = noteFiles[id]?.file {
            let parts = file.headingAndRest
            body = parts.title == nil ? file.body.trimmingCharacters(in: .whitespacesAndNewlines) : parts.rest
            links = BackendMemoryParsing.noteLinks(file.body)
            short = file.value("short").flatMap { $0.isEmpty ? nil : $0 }
            shortBy = file.value("short_by").flatMap(DeckMemoryShortTitle.Maker.init(rawValue:))
        }
        let date = row.date(8) ?? now()
        var note = DeckMemoryNote(id: row.text(0), title: row.text(2), body: body, type: .init(rawValue: row.text(3)),
            labels: .init(owner: owner, project: row.string(5), session: row.string(6), agent: row.string(7), date: date, type: row.text(3),
                          hand: row.optionalInt(16), job: row.string(17)),
            path: path, supersedes: row.string(10), supersededBy: row.string(11), archivedAt: row.date(12), archiveReason: row.string(13),
            source: row.text(9), links: links, updatedAt: row.date(15) ?? date, validFrom: row.date(18) ?? date, validUntil: row.date(19),
            diaryRange: row.isNull(20) || row.isNull(21) ? nil : min(row.int(20), row.int(21))...max(row.int(20), row.int(21)),
            author: row.string(22).flatMap(DeckMemoryAuthor.init(rawValue:)))
        note.shortTitle = short; note.shortTitleBy = short == nil ? nil : (shortBy ?? .person)
        return note
    }
    /// Lower-case with spaces squeezed: two notes that read the same have the same one.
    static func normalized(_ title: String, _ body: String) -> String {
        DeckMemoryFiles.hash((title + "\n" + body).lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " "))
    }
    static func diaryRange(_ text: String?) -> ClosedRange<Int64>? {
        guard let text else { return nil }
        let parts = text.split(separator: "-").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first, let last = parts.last, first > 0, last > 0 else { return nil }
        return min(first, last)...max(first, last)
    }
    func noteRow(_ id: String) throws -> DeckMemoryRow? {
        try db.first("SELECT \(Self.noteColumns) FROM notes WHERE id = ? AND missing = 0", [.text(id)])
    }
    static func newNoteID(_ date: Date) -> String { "n-" + DeckMemoryFiles.day(date).replacingOccurrences(of: "-", with: "") + "-" + DeckMemoryFiles.shortID() }
    static func stem(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }
    /// Writes the app's labels into a note file's label block.
    static func stampLabels(_ file: inout DeckMemoryFile, id: String, type: String, labels: DeckMemoryLabels, source: String) {
        file.set("id", id); file.set("type", type)
        file.set("seat", labels.owner.key); file.set("owner", nil)
        file.set("category", labels.owner.category?.rawValue)
        file.set("project", labels.project); file.set("session", labels.session)
        file.set("hand", labels.hand.map(String.init)); file.set("job", labels.job)
        file.set("hire", labels.agent); file.set("agent", nil)
        file.set("date", DeckMemoryFiles.stamp(labels.date)); file.set("source", source)
    }

    /// Reads one note file and brings its index row and search row in line. A file with no id (dropped in by hand)
    /// gets its labels written into it. Returns the note's id, and whether anything about it changed.
    @discardableResult
    func indexNote(path: String, pathOwner: DeckMemoryOwner, archivedByPath: Bool, text given: String? = nil) throws -> (id: String, changed: Bool)? {
        guard var text = given ?? DeckMemoryFiles.read(url(path)), var info = DeckMemoryFiles.info(url(path)) else { return nil }
        var file = DeckMemoryFile(text: text)
        let modified = Date(timeIntervalSince1970: info.mtime)
        var id = file.value("id") ?? ""
        // The same id at another path whose file is still there means this is a copy: it becomes its own note.
        if !id.isEmpty, let other = try db.first("SELECT path FROM notes WHERE id = ? AND missing = 0", [.text(id)])?.text(0), other != path,
           FileManager.default.fileExists(atPath: url(other).path) { id = "" }
        if id.isEmpty {
            id = Self.newNoteID(modified)
            let owner = DeckMemoryOwner(key: file.value("seat") ?? file.value("owner") ?? "") ?? pathOwner
            let labels = DeckMemoryLabels(owner: owner, project: file.value("project") ?? owner.projectID, session: file.value("session"),
                                          agent: file.value("hire") ?? file.value("agent"), date: DeckMemoryFiles.date(file.value("date")) ?? modified,
                                          type: file.value("type") ?? "note", hand: file.value("hand").flatMap(Int.init), job: file.value("job"))
            Self.stampLabels(&file, id: id, type: labels.type, labels: labels, source: file.value("source") ?? "outside")
            text = file.text
            try DeckMemoryFiles.write(text, to: url(path))
            info = DeckMemoryFiles.info(url(path)) ?? info
        }
        let hash = DeckMemoryFiles.hash(text)
        noteFiles[id] = (hash, file)
        let known = try db.first("SELECT path, hash, missing, archived FROM notes WHERE id = ?", [.text(id)])
        if let known, known.text(0) == path, known.text(1) == hash, known.int(2) == 0, known.isNull(3) != archivedByPath {
            try db.run("UPDATE notes SET mtime = ?, bytes = ? WHERE id = ?", [.real(info.mtime), .int(Int64(info.bytes)), .text(id)])
            return (id, false)
        }
        let parsed = BackendMemoryParsing.parseNote(text, file: path), parts = file.headingAndRest
        let title = parts.title ?? parsed.name ?? Self.stem(path)
        let owner = DeckMemoryOwner(key: file.value("seat") ?? file.value("owner") ?? "") ?? pathOwner
        let date = DeckMemoryFiles.date(file.value("date")) ?? modified
        let type = file.value("type") ?? "note"
        let archived: Date? = archivedByPath ? (DeckMemoryFiles.date(file.value("archived")) ?? modified) : nil
        let origin: String? = archivedByPath ? (path.hasPrefix("archive/") ? String(path.dropFirst("archive/".count)) : path) : nil
        let validFrom = DeckMemoryFiles.date(file.value("valid_from")) ?? date, validUntil = DeckMemoryFiles.date(file.value("valid_until"))
        let range = Self.diaryRange(file.value("diary")), reason = archivedByPath ? (file.value("archive_reason") ?? "archived") : nil
        let replaced = reason == "superseded" || reason == "merged"
        // Another row still holding this path belongs to a file that is gone: it steps aside, it is not dropped.
        try db.run("UPDATE notes SET missing = 1, path = path || '#replaced-' || id WHERE path = ? AND id != ?", [.text(path), .text(id)])
        try db.run("""
            INSERT INTO notes (id, path, title, type, owner, project, session, agent, date, source, supersedes, superseded_by, archived, archive_reason, origin_path, mtime, bytes, hash, missing, updated, hand, job, valid_from, valid_until, diary_first, diary_last, norm, author)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET path = excluded.path, title = excluded.title, type = excluded.type, owner = excluded.owner, project = excluded.project,
                session = excluded.session, agent = excluded.agent, date = excluded.date, source = excluded.source, supersedes = excluded.supersedes,
                superseded_by = excluded.superseded_by, archived = excluded.archived, archive_reason = excluded.archive_reason, origin_path = excluded.origin_path,
                mtime = excluded.mtime, bytes = excluded.bytes, hash = excluded.hash, missing = 0, updated = excluded.updated,
                hand = excluded.hand, job = excluded.job, valid_from = excluded.valid_from, valid_until = excluded.valid_until,
                diary_first = excluded.diary_first, diary_last = excluded.diary_last, norm = excluded.norm, author = excluded.author
            """, [.text(id), .text(path), .text(title), .text(type), .text(owner.key), .optional(file.value("project") ?? owner.projectID),
                  .optional(file.value("session")), .optional(file.value("hire") ?? file.value("agent")), .date(date), .text(file.value("source") ?? ""),
                  .optional(file.value("supersedes")), .optional(file.value("superseded_by")), .optional(archived),
                  .optional(reason), .optional(origin),
                  .real(info.mtime), .int(Int64(info.bytes)), .text(hash), .date(modified),
                  .optional(file.value("hand").flatMap(Int.init)), .optional(file.value("job")),
                  .date(validFrom), .optional(validUntil), range.map { .int($0.lowerBound) } ?? .null, range.map { .int($0.upperBound) } ?? .null,
                  .text(Self.normalized(title, parts.title == nil ? file.body : parts.rest)),
                  .optional(file.value("author").flatMap(DeckMemoryAuthor.init(rawValue:))?.rawValue)])
        // The search index dates a note by when it became true, so "since / until" finds the right ones.
        let labels = DeckMemoryLabels(owner: owner, project: file.value("project") ?? owner.projectID, session: file.value("session"),
                                      agent: file.value("hire") ?? file.value("agent"), date: validFrom, type: type,
                                      hand: file.value("hand").flatMap(Int.init), job: file.value("job"))
        try setSearch(kind: .note, ref: id, labels: labels, archived: archivedByPath, title: title, body: parts.title == nil ? file.body : parts.rest, replaced: replaced)
        return (id, true)
    }

    // MARK: Notes

    public func addNote(_ draft: DeckMemoryNoteDraft) async throws -> DeckMemoryNote {
        // Secrets never reach a note file.
        var body = DeckMemoryRedaction.redacted(draft.body.trimmingCharacters(in: .whitespacesAndNewlines))
        var title = DeckMemoryRedaction.redacted(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
        if title.isEmpty { title = String(body.components(separatedBy: "\n").first?.prefix(80) ?? "") }
        guard !title.isEmpty else { throw DeckMemoryError(.invalid, "A note needs a title or some text.") }
        // The same words already in this seat: nothing is written, the note that is there comes back.
        if let same = try db.first("SELECT \(Self.noteColumns) FROM notes WHERE owner = ? AND norm = ? AND missing = 0 AND archived IS NULL LIMIT 1",
                                   [.text(draft.stamp.owner.key), .text(Self.normalized(title, body))]) {
            var existing = note(same); existing.duplicateOf = existing.id
            return existing
        }
        let date = draft.date ?? now(), validFrom = draft.validFrom ?? date, id = Self.newNoteID(date)
        var replaced: DeckMemoryRow?, notReplaced: String?, lateFor: DeckMemoryRow?
        if let old = draft.supersedes, !old.isEmpty {
            guard let row = try noteRow(old) else { throw missing("The note this one replaces (\(old)) is not in memory.") }
            let oldFrom = row.date(18) ?? row.date(8) ?? date
            // Whose words each note holds. Without a recorded author, a note the person wrote by hand ("user") counts as theirs.
            let oldFromPerson = row.string(22) == DeckMemoryAuthor.person.rawValue || (row.isNull(22) && row.text(9) == "user")
            let newFromPerson = draft.author == .person || (draft.author == nil && draft.source == "user")
            if oldFromPerson, !newFromPerson {
                // What the person said stands until the person changes it.
                notReplaced = "A note that holds the person's own words can only be replaced by the person's own words. Both are kept; this one is linked to it."
                let link = "Related to [[" + Self.stem(row.text(1)) + "]]."
                if !body.contains(link) { body += (body.isEmpty ? "" : "\n\n") + link }
            } else if validFrom < oldFrom {
                // It arrived later but describes an earlier state: it is history, the newer truth stays current.
                notReplaced = "This describes an earlier state than the note it was meant to replace, so it was kept as history and that note stays current."
                lateFor = row
            } else {
                replaced = row
                // The link to what it replaced stays in the text, so it reads right in any Markdown app.
                let link = "Replaces [[" + Self.stem(row.text(1)) + "]]."
                if !body.contains(link) { body += (body.isEmpty ? "" : "\n\n") + link }
            }
        }
        let labels = DeckMemoryLabels(stamp: draft.stamp, date: date, type: draft.type.rawValue)
        var name = DeckMemoryFiles.day(date) + "-" + String(DeckMemoryOwner.slug(title).prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        name += "-" + String(id.suffix(6)) + ".md"
        let path = draft.stamp.owner.notesFolder + "/" + name
        var file = DeckMemoryFile(body: "# " + title + "\n\n" + body + "\n")
        Self.stampLabels(&file, id: id, type: draft.type.rawValue, labels: labels, source: draft.source)
        file.set("valid_from", DeckMemoryFiles.stamp(validFrom))
        file.set("author", draft.author?.rawValue)
        // Every note has its very short title from the moment it is saved: the one given (the helper writes one with its
        // notes), else the first words, which the titles job replaces with the helper's own in the background.
        let given = DeckMemoryShortTitle.cleaned(draft.shortTitle.map(DeckMemoryRedaction.redacted))
        file.set("short", given ?? DeckMemoryShortTitle.fallback(title))
        file.set("short_by", (given == nil ? DeckMemoryShortTitle.Maker.firstWords : draft.source == "user" ? .person : .helper).rawValue)
        if let range = draft.diaryRange { file.set("diary", "\(range.lowerBound)-\(range.upperBound)") }
        file.set("supersedes", replaced?.text(0))
        try db.transaction {
            try DeckMemoryFiles.write(file.text, to: url(path))
            try indexNote(path: path, pathOwner: draft.stamp.owner, archivedByPath: false, text: file.text)
            if let replaced { _ = try archiveNow(id: replaced.text(0), reason: "superseded", replacedBy: id, until: validFrom) }
            if let lateFor { _ = try archiveNow(id: id, reason: "history", replacedBy: lateFor.text(0), until: lateFor.date(18) ?? lateFor.date(8)) }
        }
        post(.notes, draft.stamp.owner, id)
        kickEmbedding()
        guard let row = try noteRow(id) else { throw DeckMemoryError(.io, "The note was written but could not be read back.") }
        var saved = note(row); saved.notReplaced = notReplaced
        return saved
    }

    public func updateNote(id: String, title: String?, body: String?, type: DeckMemoryNoteType?) async throws -> DeckMemoryNote {
        guard let row = try noteRow(id), let text = DeckMemoryFiles.read(url(row.text(1))) else { throw missing("That note is not in memory any more.") }
        var file = DeckMemoryFile(text: text)
        let parts = file.headingAndRest
        let newTitle = (title ?? row.text(2)).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !newTitle.isEmpty else { throw DeckMemoryError(.invalid, "A note needs a title.") }
        let oldBody = parts.title == nil ? file.body.trimmingCharacters(in: .whitespacesAndNewlines) : parts.rest
        file.body = DeckMemoryRedaction.redacted("# " + newTitle + "\n\n" + (body ?? oldBody).trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        if let type { file.set("type", type.rawValue) }
        // The words changed: a short title the app or the helper made is made again (first words now, the helper's later).
        // One the person wrote stays.
        if file.body != DeckMemoryFile(text: text).body, file.value("short_by") != DeckMemoryShortTitle.Maker.person.rawValue {
            file.set("short", DeckMemoryShortTitle.fallback(newTitle)); file.set("short_by", DeckMemoryShortTitle.Maker.firstWords.rawValue)
        }
        guard file.text != text else { return note(row) }
        keepVersion(of: row.text(1))
        try DeckMemoryFiles.write(file.text, to: url(row.text(1)))
        let owner = DeckMemoryOwner(key: row.text(4)) ?? .hoot
        try indexNote(path: row.text(1), pathOwner: owner, archivedByPath: !row.isNull(12), text: file.text)
        post(.notes, owner, id); kickEmbedding()
        return note(try noteRow(id)!)
    }

    /// Sets a note's very short title (3 to 6 words) and who made it. Only the label block changes: the text, its date and
    /// its history stay as they are. A title the person wrote is never replaced by the helper's.
    public func setShortTitle(noteID id: String, short: String, by maker: DeckMemoryShortTitle.Maker) async throws -> DeckMemoryNote {
        guard let row = try noteRow(id), let text = DeckMemoryFiles.read(url(row.text(1))) else { throw missing("That note is not in memory any more.") }
        guard let clean = DeckMemoryShortTitle.cleaned(DeckMemoryRedaction.redacted(short)) else { throw DeckMemoryError(.invalid, "A short title needs a few words.") }
        var file = DeckMemoryFile(text: text)
        if maker != .person, file.value("short_by") == DeckMemoryShortTitle.Maker.person.rawValue { return note(row) }
        file.set("short", clean); file.set("short_by", maker.rawValue)
        guard file.text != text else { return note(row) }
        try DeckMemoryFiles.write(file.text, to: url(row.text(1)))
        let owner = DeckMemoryOwner(key: row.text(4)) ?? .hoot
        try indexNote(path: row.text(1), pathOwner: owner, archivedByPath: !row.isNull(12), text: file.text)
        post(.notes, owner, id)
        return note(try noteRow(id)!)
    }

    public func archiveNote(id: String, reason: String, replacedBy: String?) async throws -> DeckMemoryNote {
        // Replaced by another note: it stopped being true when that one became true.
        let until = try replacedBy.flatMap { try noteRow($0) }.flatMap { $0.date(18) ?? $0.date(8) }
        let saved = try archiveNow(id: id, reason: replacedBy == nil ? reason : (reason == "archived" || reason.isEmpty ? "superseded" : reason), replacedBy: replacedBy, until: until)
        post(.notes, saved.labels.owner, id)
        return saved
    }
    /// Moves the file under `archive/` at the same path and marks it. Nothing is removed.
    func archiveNow(id: String, reason: String, replacedBy: String?, until: Date? = nil) throws -> DeckMemoryNote {
        guard let row = try noteRow(id) else { throw missing("That note is not in memory any more.") }
        let path = row.text(1), owner = DeckMemoryOwner(key: row.text(4)) ?? .hoot
        guard var file = DeckMemoryFiles.read(url(path)).map(DeckMemoryFile.init(text:)) else { throw missing("That note's file is gone from the memory folder.") }
        if let replacedBy, !replacedBy.isEmpty { file.set("superseded_by", replacedBy) }
        if let until { file.set("valid_until", DeckMemoryFiles.stamp(until)) }
        if !row.isNull(12) {
            // Already archived: only the "replaced by" link can still be added.
            if replacedBy != nil { try DeckMemoryFiles.write(file.text, to: url(path)); try indexNote(path: path, pathOwner: owner, archivedByPath: true, text: file.text) }
            return note(try noteRow(id)!)
        }
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        file.set("archived", DeckMemoryFiles.stamp(now())); file.set("archive_reason", clean.isEmpty ? "archived" : clean)
        file.set("status", ["superseded", "merged", "history"].contains(clean) ? clean : "archived")
        var target = "archive/" + path, counter = 1
        while FileManager.default.fileExists(atPath: url(target).path) {
            counter += 1; target = "archive/" + String(path.dropLast(3)) + "-\(counter).md"
        }
        try DeckMemoryFiles.write(file.text, to: url(path))
        do {
            try FileManager.default.createDirectory(at: url(target).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url(path), to: url(target))
        } catch { throw DeckMemoryError(.io, "The note could not be moved to the archive: \(error.localizedDescription)") }
        try indexNote(path: target, pathOwner: owner, archivedByPath: true, text: file.text)
        try db.run("UPDATE notes SET origin_path = ? WHERE id = ?", [.text(path), .text(id)])
        return note(try noteRow(id)!)
    }

    public func restoreNote(id: String) async throws -> DeckMemoryNote {
        guard let row = try noteRow(id) else { throw missing("That note is not in memory any more.") }
        guard !row.isNull(12) else { return note(row) }
        let path = row.text(1), owner = DeckMemoryOwner(key: row.text(4)) ?? .hoot
        guard var file = DeckMemoryFiles.read(url(path)).map(DeckMemoryFile.init(text:)) else { throw missing("That note's file is gone from the memory folder.") }
        let origin = row.string(14) ?? (path.hasPrefix("archive/") ? String(path.dropFirst("archive/".count)) : path)
        var target = origin, counter = 1
        while FileManager.default.fileExists(atPath: url(target).path) {
            counter += 1; target = String(origin.dropLast(3)) + "-\(counter).md"
        }
        file.set("archived", nil); file.set("archive_reason", nil); file.set("status", nil); file.set("valid_until", nil)
        try DeckMemoryFiles.write(file.text, to: url(path))
        do {
            try FileManager.default.createDirectory(at: url(target).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url(path), to: url(target))
        } catch { throw DeckMemoryError(.io, "The note could not be brought back: \(error.localizedDescription)") }
        // Retest 11 Oct: a restore left its emptied folder under archive/. Remove folders the move emptied,
        // walking up, but never archive/ itself and never a folder that still holds anything.
        if path.hasPrefix("archive/") {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.hasPrefix("archive/"), folder != "archive",
                  let left = try? FileManager.default.contentsOfDirectory(atPath: url(folder).path),
                  left.filter({ $0 != ".DS_Store" }).isEmpty {
                try? FileManager.default.removeItem(at: url(folder))
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        try indexNote(path: target, pathOwner: owner, archivedByPath: false, text: file.text)
        post(.notes, owner, id); kickEmbedding()
        return note(try noteRow(id)!)
    }

    public func note(id: String) async throws -> DeckMemoryNote? { try noteRow(id).map(note) }

    public func notes(_ query: DeckMemoryNoteQuery) async throws -> [DeckMemoryNote] {
        var clauses = ["missing = 0"], args: [DeckMemorySQL] = []
        if let owner = query.owner { let clause = Self.ownerClause(owner); clauses.append(clause.sql); args += clause.args }
        if let project = query.project { let clause = Self.projectClause(project); clauses.append(clause.sql); args += clause.args }
        if let session = query.session { clauses.append("session = ?"); args.append(.text(session)) }
        if let agent = query.agent { clauses.append("agent = ?"); args.append(.text(agent)) }
        if let type = query.type { clauses.append("type = ?"); args.append(.text(type.rawValue)) }
        if let job = query.job { clauses.append("job = ?"); args.append(.text(job)) }
        if let since = query.since { clauses.append("date >= ?"); args.append(.date(since)) }
        if query.archivedOnly { clauses.append("archived IS NOT NULL") }
        else if !query.includeArchived { clauses.append("archived IS NULL") }
        args.append(.int(Int64(max(1, min(query.limit, 5000)))))
        return try db.rows("SELECT \(Self.noteColumns) FROM notes WHERE \(clauses.joined(separator: " AND ")) ORDER BY date DESC, id DESC LIMIT ?", args).map(note)
    }

    public func history(ofNote id: String) async throws -> [DeckMemoryNote] {
        var chain: [DeckMemoryNote] = [], seen: Set<String> = [id]
        var next = try noteRow(id)?.string(10)
        while let current = next, seen.insert(current).inserted, chain.count < 100, let row = try noteRow(current) {
            chain.append(note(row)); next = row.string(10)
        }
        return chain
    }

    // MARK: Topics

    static let topicColumns = "owner, id, title, path, open, project, session, agent, date, hand, job"
    func topic(_ row: DeckMemoryRow) -> DeckMemoryTopic {
        let owner = DeckMemoryOwner(key: row.text(0)) ?? .hoot, path = row.text(3), date = row.date(8) ?? now()
        var body = ""
        if let text = DeckMemoryFiles.read(url(path)) {
            let file = DeckMemoryFile(text: text), parts = file.headingAndRest
            body = parts.title == nil ? file.body.trimmingCharacters(in: .whitespacesAndNewlines) : parts.rest
        }
        return DeckMemoryTopic(id: row.text(1), owner: owner, title: row.text(2), body: body, open: row.int(4) != 0, path: path,
            labels: .init(owner: owner, project: row.string(5), session: row.string(6), agent: row.string(7), date: date, type: "topic",
                          hand: row.optionalInt(9), job: row.string(10)), updatedAt: date)
    }
    @discardableResult
    func indexTopic(path: String, owner: DeckMemoryOwner, id: String, text given: String? = nil) throws -> Bool {
        guard let text = given ?? DeckMemoryFiles.read(url(path)), let info = DeckMemoryFiles.info(url(path)) else { return false }
        let hash = DeckMemoryFiles.hash(text)
        if let known = try db.first("SELECT hash, missing FROM topics WHERE owner = ? AND id = ?", [.text(owner.key), .text(id)]), known.text(0) == hash, known.int(1) == 0 {
            try db.run("UPDATE topics SET mtime = ?, bytes = ? WHERE owner = ? AND id = ?", [.real(info.mtime), .int(Int64(info.bytes)), .text(owner.key), .text(id)])
            return false
        }
        let file = DeckMemoryFile(text: text), parts = file.headingAndRest
        let title = file.value("title") ?? parts.title ?? id
        let open = !["closed", "done", "rewound"].contains((file.value("status") ?? "open").lowercased())
        let date = DeckMemoryFiles.date(file.value("date")) ?? Date(timeIntervalSince1970: info.mtime)
        try db.run("UPDATE topics SET missing = 1, path = path || '#replaced' WHERE path = ? AND NOT (owner = ? AND id = ?)", [.text(path), .text(owner.key), .text(id)])
        try db.run("""
            INSERT INTO topics (owner, id, title, path, open, project, session, agent, date, mtime, bytes, hash, missing, hand, job) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
            ON CONFLICT(owner, id) DO UPDATE SET title = excluded.title, path = excluded.path, open = excluded.open, project = excluded.project, session = excluded.session,
                agent = excluded.agent, date = excluded.date, mtime = excluded.mtime, bytes = excluded.bytes, hash = excluded.hash, missing = 0,
                hand = excluded.hand, job = excluded.job
            """, [.text(owner.key), .text(id), .text(title), .text(path), .bool(open), .optional(file.value("project") ?? owner.projectID),
                  .optional(file.value("session")), .optional(file.value("hire") ?? file.value("agent")), .date(date),
                  .real(info.mtime), .int(Int64(info.bytes)), .text(hash), .optional(file.value("hand").flatMap(Int.init)), .optional(file.value("job"))])
        let labels = DeckMemoryLabels(owner: owner, project: file.value("project") ?? owner.projectID, session: file.value("session"),
                                      agent: file.value("hire") ?? file.value("agent"), date: date, type: "topic",
                                      hand: file.value("hand").flatMap(Int.init), job: file.value("job"))
        try setSearch(kind: .topic, ref: owner.key + "/" + id, labels: labels, archived: !open, title: title, body: parts.title == nil ? file.body : parts.rest)
        return true
    }
    public func topics(_ owner: DeckMemoryOwner, job: String?, includeClosed: Bool) async throws -> [DeckMemoryTopic] {
        var sql = "SELECT \(Self.topicColumns) FROM topics WHERE owner = ? AND missing = 0\(includeClosed ? "" : " AND open = 1")"
        var args: [DeckMemorySQL] = [.text(owner.key)]
        // One hand's view: its own job's topic first, then the topics that belong to the whole seat.
        if let job, !job.isEmpty { sql += " AND (job = ? OR job IS NULL)"; args.append(.text(job)) }
        return try db.rows(sql + " ORDER BY open DESC, job IS NULL, date DESC", args).map(topic)
    }
    public func topic(_ owner: DeckMemoryOwner, id: String) async throws -> DeckMemoryTopic? { try topicRow(owner, id).map(topic) }
    func topicRow(_ owner: DeckMemoryOwner, _ id: String) throws -> DeckMemoryRow? {
        try db.first("SELECT \(Self.topicColumns) FROM topics WHERE owner = ? AND id = ? AND missing = 0", [.text(owner.key), .text(id)])
    }
    public func updateTopic(_ owner: DeckMemoryOwner, title: String, body: String, stamp: DeckMemoryStamp?) async throws -> DeckMemoryTopic {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { throw DeckMemoryError(.invalid, "A topic needs a title.") }
        // A topic belongs to the JOB when there is one, so every hand on the seat keeps its own.
        let job = stamp?.job.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let id = DeckMemoryOwner.slug(job ?? clean), path = owner.topicsFolder + "/" + id + ".md"
        let labels = DeckMemoryLabels(stamp: stamp ?? .init(owner: owner), date: now(), type: "topic")
        var file = DeckMemoryFiles.read(url(path)).map(DeckMemoryFile.init(text:)) ?? DeckMemoryFile(body: "")
        let before = file.text
        file.body = DeckMemoryRedaction.redacted(body.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
        file.set("title", clean); file.set("status", "open")
        file.set("seat", owner.key); file.set("owner", nil); file.set("category", owner.category?.rawValue)
        file.set("project", labels.project); file.set("session", labels.session); file.set("hire", labels.agent); file.set("agent", nil)
        file.set("hand", labels.hand.map(String.init)); file.set("job", job)
        // The date only moves when the text does, so saving the same text twice changes nothing.
        var unchanged = file; unchanged.set("date", DeckMemoryFile(text: before).value("date"))
        if unchanged.text == before, let row = try topicRow(owner, id) { return topic(row) }
        file.set("date", DeckMemoryFiles.stamp(labels.date))
        if !before.isEmpty { keepVersion(of: path) }
        try DeckMemoryFiles.write(file.text, to: url(path))
        try indexTopic(path: path, owner: owner, id: id, text: file.text)
        post(.topics, owner, id); kickEmbedding()
        guard let row = try topicRow(owner, id) else { throw DeckMemoryError(.io, "The topic was written but could not be read back.") }
        return topic(row)
    }
    public func setTopic(_ owner: DeckMemoryOwner, id: String, open: Bool) async throws -> DeckMemoryTopic {
        guard let row = try topicRow(owner, id), let text = DeckMemoryFiles.read(url(row.text(3))) else { throw missing("That topic is not in memory any more.") }
        var file = DeckMemoryFile(text: text)
        file.set("status", open ? "open" : "closed")
        if file.value("title") == nil { file.set("title", row.text(2)) }
        guard file.text != text else { return topic(row) }
        try DeckMemoryFiles.write(file.text, to: url(row.text(3)))
        try indexTopic(path: row.text(3), owner: owner, id: id, text: file.text)
        post(.topics, owner, id)
        return topic(try topicRow(owner, id)!)
    }
}
