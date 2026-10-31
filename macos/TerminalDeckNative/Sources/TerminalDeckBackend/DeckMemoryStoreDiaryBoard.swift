import Foundation
import TerminalDeckNativeCore

// The diary (every message, word for word) and the board (one for the whole app). Both live in memory.db.
extension DeckMemoryStore {
    static let diaryColumns = "id, owner, project, session, agent, role, text, conversation, turn, external_id, at, meta, hand, job, author, rewound"

    func diaryEntry(_ row: DeckMemoryRow) -> DeckMemoryDiaryEntry {
        let owner = DeckMemoryOwner(key: row.text(1)) ?? .hoot, role = DeckMemoryDiaryRole(rawValue: row.text(5)) ?? .event
        let meta = (try? JSONDecoder().decode([String: String].self, from: Data(row.text(11).utf8))) ?? [:]
        return .init(id: row.int(0), labels: .init(owner: owner, project: row.string(2), session: row.string(3), agent: row.string(4),
                                                    date: row.date(10) ?? now(), type: role.rawValue, hand: row.optionalInt(12), job: row.string(13)),
                     role: role, text: row.text(6), conversation: row.string(7), turn: row.string(8), externalID: row.string(9), meta: meta,
                     author: row.string(14).flatMap(DeckMemoryAuthor.init(rawValue:)), rewoundAt: row.date(15))
    }
    /// Roles whose text is worth matching by meaning.
    static let diaryMeaningRoles: Set<DeckMemoryDiaryRole> = [.user, .assistant]

    func appendNow(_ draft: DeckMemoryDiaryDraft) throws -> (entry: DeckMemoryDiaryEntry, new: Bool) {
        if let key = draft.externalID, !key.isEmpty,
           let same = try db.first("SELECT \(Self.diaryColumns) FROM diary WHERE external_id = ?", [.text(key)]) {
            return (diaryEntry(same), false)
        }
        let saved = now(), at = draft.at ?? saved
        let meta = draft.meta.isEmpty ? "{}" : String(decoding: (try? JSONEncoder().encode(draft.meta)) ?? Data("{}".utf8), as: UTF8.self)
        let external = draft.externalID.flatMap { $0.isEmpty ? nil : $0 }
        let id = try db.run("INSERT INTO diary (owner, project, session, agent, role, text, conversation, turn, external_id, at, saved, meta, hand, job, author) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(draft.stamp.owner.key), .optional(draft.stamp.project), .optional(draft.stamp.session), .optional(draft.stamp.agent),
             .text(draft.role.rawValue), .text(draft.text), .optional(draft.conversation), .optional(draft.turn), .optional(external),
             .date(at), .date(saved), .text(meta), .optional(draft.stamp.hand), .optional(draft.stamp.job), .optional(draft.author?.rawValue)])
        let labels = DeckMemoryLabels(stamp: draft.stamp, date: at, type: draft.role.rawValue)
        if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try setSearch(kind: .diary, ref: String(id), labels: labels, archived: false, title: "", body: draft.text)
            // Tool output and app events are found by their words; only what people and AIs say is matched by meaning.
            if !Self.diaryMeaningRoles.contains(draft.role) || draft.text.count < 12 {
                try db.run("DELETE FROM embed_queue WHERE kind = 'diary' AND ref = ?", [.text(String(id))])
            }
        }
        return (.init(id: id, labels: labels, role: draft.role, text: draft.text, conversation: draft.conversation, turn: draft.turn,
                      externalID: external, meta: draft.meta, author: draft.author), true)
    }
    public func appendDiary(_ draft: DeckMemoryDiaryDraft) async throws -> DeckMemoryDiaryEntry {
        let result = try db.transaction { try appendNow(draft) }
        if result.new { post(.diary, draft.stamp.owner, String(result.entry.id)); kickEmbedding() }
        return result.entry
    }
    public func appendDiary(_ drafts: [DeckMemoryDiaryDraft]) async throws -> [DeckMemoryDiaryEntry] {
        guard !drafts.isEmpty else { return [] }
        let results = try db.transaction { try drafts.map(appendNow) }
        // One notice per seat for the whole batch.
        var told = Set<DeckMemoryOwner>()
        for result in results where result.new && told.insert(result.entry.labels.owner).inserted {
            post(.diary, result.entry.labels.owner, String(results.last { $0.new && $0.entry.labels.owner == result.entry.labels.owner }?.entry.id ?? result.entry.id))
        }
        if results.contains(where: \.new) { kickEmbedding() }
        return results.map(\.entry)
    }
    public func diary(_ query: DeckMemoryDiaryQuery) async throws -> [DeckMemoryDiaryEntry] {
        var clauses: [String] = [], args: [DeckMemorySQL] = []
        if let owner = query.owner { let clause = Self.ownerClause(owner); clauses.append(clause.sql); args += clause.args }
        if let project = query.project { let clause = Self.projectClause(project); clauses.append(clause.sql); args += clause.args }
        if let session = query.session { clauses.append("session = ?"); args.append(.text(session)) }
        if let agent = query.agent { clauses.append("agent = ?"); args.append(.text(agent)) }
        if let conversation = query.conversation { clauses.append("conversation = ?"); args.append(.text(conversation)) }
        if let job = query.job { clauses.append("job = ?"); args.append(.text(job)) }
        // A rewound row is history: it is not part of the live conversation unless the caller asks for the history.
        if !query.includeRewound { clauses.append("rewound IS NULL") }
        if let authors = query.authors {
            guard !authors.isEmpty else { return [] }
            clauses.append("author IN (" + authors.map { _ in "?" }.joined(separator: ", ") + ")"); args += authors.map { .text($0.rawValue) }
        }
        if let roles = query.roles {
            guard !roles.isEmpty else { return [] }
            clauses.append("role IN (" + roles.map { _ in "?" }.joined(separator: ", ") + ")"); args += roles.map { .text($0.rawValue) }
        }
        if let after = query.after { clauses.append("id > ?"); args.append(.int(after)) }
        if let before = query.before { clauses.append("id < ?"); args.append(.int(before)) }
        if let since = query.since { clauses.append("at >= ?"); args.append(.date(since)) }
        if let until = query.until { clauses.append("at <= ?"); args.append(.date(until)) }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        args.append(.int(Int64(max(1, min(query.limit, 20_000)))))
        // Paging back ("before") without an order asked for still means the rows just before, in reading order.
        let newest = query.newestFirst || (query.before != nil && query.after == nil)
        let rows = try db.rows("SELECT \(Self.diaryColumns) FROM diary\(filter) ORDER BY id \(newest ? "DESC" : "ASC") LIMIT ?", args).map(diaryEntry)
        return newest && !query.newestFirst ? rows.reversed() : rows
    }
    public func diary(around id: Int64, before: Int, after: Int) async throws -> [DeckMemoryDiaryEntry] {
        guard let row = try db.first("SELECT \(Self.diaryColumns) FROM diary WHERE id = ?", [.int(id)]) else { throw missing("That moment is not in the diary.") }
        let middle = diaryEntry(row)
        var scope = "", args: [DeckMemorySQL] = []
        if let conversation = middle.conversation { scope = "conversation = ?"; args = [.text(conversation)] }
        else if let session = middle.labels.session { scope = "session = ?"; args = [.text(session)] }
        else { scope = "owner = ?"; args = [.text(middle.labels.owner.key)] }
        let earlier = try db.rows("SELECT \(Self.diaryColumns) FROM diary WHERE \(scope) AND id < ? ORDER BY id DESC LIMIT ?", args + [.int(id), .int(Int64(max(0, before)))]).map(diaryEntry)
        let later = try db.rows("SELECT \(Self.diaryColumns) FROM diary WHERE \(scope) AND id > ? ORDER BY id ASC LIMIT ?", args + [.int(id), .int(Int64(max(0, after)))]).map(diaryEntry)
        return earlier.reversed() + [middle] + later
    }
    public func diaryHead(session: String?) async throws -> Int64 {
        if let session { return try db.first("SELECT COALESCE(MAX(id), 0) FROM diary WHERE session = ?", [.text(session)])?.int(0) ?? 0 }
        return try db.first("SELECT COALESCE(MAX(id), 0) FROM diary")?.int(0) ?? 0
    }

    // MARK: Board

    static let boardColumns = "id, kind, title, owner, project, session, agent, doing, last_result, waiting, state, proof, updated, archived, hand, job"
    func boardRow(_ row: DeckMemoryRow) -> DeckMemoryBoardRow { Self.boardRow(row, now: now()) }
    static func boardRow(_ row: DeckMemoryRow, now: Date) -> DeckMemoryBoardRow {
        let owner = DeckMemoryOwner(key: row.text(3)) ?? .hoot, kind = DeckMemoryBoardKind(rawValue: row.text(1)) ?? .session
        let updated = row.date(12) ?? now
        return .init(id: row.text(0), kind: kind, title: row.text(2),
                     labels: .init(owner: owner, project: row.string(4), session: row.string(5), agent: row.string(6), date: updated, type: kind.rawValue,
                                   hand: row.optionalInt(14), job: row.string(15)),
                     doing: row.text(7), lastResult: row.text(8), waitingForUser: row.text(9), state: row.string(10).flatMap(DeckMemoryResultState.init(rawValue:)),
                     proof: row.text(11), updatedAt: updated, archivedAt: row.date(13))
    }
    func boardRow(id: String) throws -> DeckMemoryBoardRow? {
        try db.first("SELECT \(Self.boardColumns) FROM board WHERE id = ?", [.text(id)]).map(boardRow)
    }
    /// How long the board's history keeps every change. Older changes go, except each row's newest one
    /// (the opening text only needs the last change per row since a moment): a session flips between
    /// working and idle hundreds of times a day, and without this the table grew for good.
    static let boardHistoryKept: TimeInterval = 7 * 86_400
    /// The week trim run after each change: one row's entries older than the week, except its newest (the entry just
    /// written, `id < ?`). Read through (row_id, at), so it touches only the entries it deletes. It used to find them
    /// by walking every entry of the row through (row_id, id) and reading each one's time from the table: 28 Oct
    /// 2026, a lead whose sessions flip between working and idle all day had 63,000 entries in its week, and that walk
    /// ran on every status change (about 0.4 s of CPU in every 5 s in Asad's app).
    static let boardHistoryTrimSQL = "DELETE FROM board_history INDEXED BY board_history_row_at WHERE row_id = ? AND at < ? AND id < ?"
    private func recordBoard(_ row: DeckMemoryBoardRow, fields: [String], at: Date) throws {
        let snapshot = String(decoding: (try? JSONEncoder().encode(row)) ?? Data("{}".utf8), as: UTF8.self)
        let newest = try db.run("INSERT INTO board_history (row_id, at, fields, snapshot) VALUES (?, ?, ?, ?)",
                                [.text(row.id), .date(at), .text(fields.joined(separator: ",")), .text(snapshot)])
        // The entry just written is the row's newest (ids only grow), so it is always kept, as before.
        try db.run(Self.boardHistoryTrimSQL, [.text(row.id), .date(at.addingTimeInterval(-Self.boardHistoryKept)), .int(newest)])
    }
    /// The same for rows that no longer change (closed sessions), once per opening.
    func trimBoardHistory() throws {
        try db.run("DELETE FROM board_history WHERE at < ? AND id NOT IN (SELECT MAX(id) FROM board_history GROUP BY row_id)",
                   [.date(now().addingTimeInterval(-Self.boardHistoryKept))])
    }
    public func updateBoard(_ update: DeckMemoryBoardUpdate) async throws -> DeckMemoryBoardRow {
        guard !update.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeckMemoryError(.invalid, "A board row needs an id.") }
        let at = now()
        let existing = try boardRow(id: update.id)
        var row = existing ?? DeckMemoryBoardRow(id: update.id, kind: update.kind, title: "",
            labels: .init(stamp: update.stamp, date: at, type: update.kind.rawValue), updatedAt: at)
        var fields: [String] = existing == nil ? ["created"] : []
        func change(_ name: String, _ current: inout String, _ next: String?) {
            guard let next, next != current else { return }
            current = next; fields.append(name)
        }
        change("title", &row.title, update.title)
        change("doing", &row.doing, update.doing)
        let resultChanged = update.lastResult != nil && update.lastResult != row.lastResult
        change("lastResult", &row.lastResult, update.lastResult)
        change("waitingForUser", &row.waitingForUser, update.waitingForUser)
        change("proof", &row.proof, update.proof)
        // A new result starts as "attempted" unless the app says how far it got. A cleared result has no state.
        var state = update.state ?? (resultChanged ? (row.lastResult.isEmpty ? nil : .attempted) : row.state)
        // Proof belongs to one result: a new result without its own proof starts with none.
        if resultChanged, update.proof == nil, !row.proof.isEmpty { row.proof = ""; fields.append("proof") }
        if row.lastResult.isEmpty, update.state == nil { state = nil }
        if state == .verified, row.proof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DeckMemoryError(.proofRequired, "A result can only be marked verified with the proof: say where it was checked.")
        }
        if state != row.state { row.state = state; fields.append("state") }
        // Who it belongs to follows the latest app event (a session can move between seats).
        let labels = DeckMemoryLabels(stamp: update.stamp, date: at, type: row.kind.rawValue)
        if existing != nil, labels.stamp != row.labels.stamp { fields.append("labels") }
        if existing?.archivedAt != nil { row.archivedAt = nil; fields.append("archived") }
        guard !fields.isEmpty else { return row }
        row.labels = labels; row.updatedAt = at
        try db.transaction {
            try db.run("""
                INSERT INTO board (id, kind, title, owner, project, session, agent, doing, last_result, waiting, state, proof, updated, archived, hand, job)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, owner = excluded.owner, project = excluded.project, session = excluded.session,
                    agent = excluded.agent, doing = excluded.doing, last_result = excluded.last_result, waiting = excluded.waiting, state = excluded.state,
                    proof = excluded.proof, updated = excluded.updated, archived = NULL, hand = excluded.hand, job = excluded.job
                """, [.text(row.id), .text(row.kind.rawValue), .text(row.title), .text(labels.owner.key), .optional(labels.project), .optional(labels.session),
                      .optional(labels.agent), .text(row.doing), .text(row.lastResult), .text(row.waitingForUser), .optional(row.state?.rawValue),
                      .text(row.proof), .date(at), .optional(labels.hand), .optional(labels.job)])
            try recordBoard(row, fields: fields, at: at)
        }
        post(.board, labels.owner, row.id)
        return row
    }
    public func board(_ query: DeckMemoryBoardQuery) async throws -> [DeckMemoryBoardRow] {
        var clauses: [String] = [], args: [DeckMemorySQL] = []
        if let owner = query.owner, let clause = Self.scopeClause(owner) { clauses.append(clause.sql); args += clause.args }
        if let project = query.project { let clause = Self.projectClause(project); clauses.append(clause.sql); args += clause.args }
        if let session = query.session { clauses.append("session = ?"); args.append(.text(session)) }
        if let agent = query.agent { clauses.append("agent = ?"); args.append(.text(agent)) }
        if let seat = query.seat { clauses.append("owner = ?"); args.append(.text(seat.key)) }
        if let job = query.job { clauses.append("job = ?"); args.append(.text(job)) }
        if let kinds = query.kinds {
            guard !kinds.isEmpty else { return [] }
            clauses.append("kind IN (" + kinds.map { _ in "?" }.joined(separator: ", ") + ")"); args += kinds.map { .text($0.rawValue) }
        }
        if query.waitingOnly { clauses.append("waiting != ''") }
        if let since = query.changedSince { clauses.append("updated > ?"); args.append(.date(since)) }
        if !query.includeArchived { clauses.append("archived IS NULL") }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        args.append(.int(Int64(max(1, min(query.limit, 5000)))))
        return try db.rows("SELECT \(Self.boardColumns) FROM board\(filter) ORDER BY updated DESC, id LIMIT ?", args).map(boardRow)
    }
    public func boardChanges(since: Date, owner: DeckMemoryOwner?) async throws -> [DeckMemoryBoardChange] {
        var sql = "SELECT h.id, h.at, h.fields, h.snapshot FROM board_history h JOIN board ON board.id = h.row_id WHERE h.at > ?"
        var args: [DeckMemorySQL] = [.date(since)]
        if let owner, let clause = Self.scopeClause(owner) {
            // The row's CURRENT labels decide who sees its history.
            sql += " AND " + clause.sql.replacingOccurrences(of: "project", with: "board.project").replacingOccurrences(of: "owner", with: "board.owner")
            args += clause.args
        }
        return try db.rows(sql + " ORDER BY h.id ASC LIMIT 2000", args).compactMap { row in
            guard let snapshot = try? JSONDecoder().decode(DeckMemoryBoardRow.self, from: Data(row.text(3).utf8)) else { return nil }
            return .init(id: row.int(0), row: snapshot, fields: row.text(2).split(separator: ",").map(String.init), at: row.date(1) ?? since)
        }
    }
    public func archiveBoardRow(id: String) async throws -> DeckMemoryBoardRow {
        guard var row = try boardRow(id: id) else { throw missing("That row is not on the board.") }
        guard row.archivedAt == nil else { return row }
        let at = now()
        row.archivedAt = at
        try db.transaction {
            try db.run("UPDATE board SET archived = ? WHERE id = ?", [.date(at), .text(id)])
            try recordBoard(row, fields: ["archived"], at: at)
        }
        post(.board, row.labels.owner, id)
        return row
    }
}
