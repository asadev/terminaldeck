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

    /// A working/idle state counts for the board's history only once it has held this long. The flow writes a session's
    /// status after it held (`DeckMemoryFlowEngine`), and the one-time settle below applies the same rule to older history.
    public static let boardSettleSeconds: TimeInterval = 3
    /// Marks that the board's history before 2 Nov 2026 was settled (`settleBoardHistoryOnce`). A new store gets it at once.
    static let boardHistorySettledKey = "board.history.settled"
    static let boardHistorySettledVersion = "1"
    /// Board history entries that only say "doing changed", followed by another such entry of the same row within
    /// `boardSettleSeconds` (the state did not hold). The row's newest entry is never one (it has no next).
    static let boardHistoryUnsettledSQL = """
        SELECT id, row_id, at, fields, snapshot, LEAD(at) OVER w AS next_at, LEAD(fields) OVER w AS next_fields
        FROM main.board_history WINDOW w AS (PARTITION BY row_id ORDER BY id)
        """
    /// What changed the board's history, once: `before` entries, `after` entries, and the copy taken first (nil when nothing had to go).
    public struct BoardHistorySettle: Sendable, Equatable { public var before: Int, after: Int, backup: URL?, seconds: Double }

    /// Once per store (2 Nov 2026), before the settled writer: the history is cut back to what that writer would have
    /// kept. Asad's memory held 433,000 history entries, 432,000 of them a session flipping between working and idle
    /// a moment apart (Working, then Idle 70 ms later, every 1 to 4 s), about 215 of its 285 MB.
    ///   1. An entry that only changed `doing` and was followed within 3 s by another such entry of the same row goes:
    ///      that state never held.
    ///   2. Then an entry that only changed `doing` to what the row was already doing goes (nothing changed).
    /// Every other entry stays: anything that changed a title, a result, a waiting line, proof, a state, who it belongs
    /// to, archiving; and every row's newest entry. Only `board_history` is touched (it is derived from the app's
    /// events; notes, topics, cards and the diary are never read or changed here). A copy of memory.db goes to
    /// `archive/backups` first; without that copy nothing is changed. Idempotent: a second run finds nothing to drop.
    @discardableResult
    func settleBoardHistoryOnce() throws -> BoardHistorySettle? {
        let mark = try setting(Self.boardHistorySettledKey, owner: nil)
        guard mark != Self.boardHistorySettledVersion else { return nil }
        // A settle that failed after its copy was made is tried at most three times, so a lasting failure never
        // fills the backups folder with a copy at every start (the newest seven are kept).
        let tries = mark.flatMap { $0.hasPrefix("tried-") ? Int($0.dropFirst(6)) : nil } ?? 0
        guard tries < 3 else { return nil }
        let started = Date()
        let before = Int(try db.first("SELECT COUNT(*) FROM board_history")?.int(0) ?? 0)
        let window = Self.boardSettleSeconds
        // The window (a constant) is written into the statements, so the count and the copy below use the very same test.
        let unheld = "fields = 'doing' AND next_fields IS 'doing' AND next_at - at < \(window)"
        let unsettled = try db.first("SELECT COUNT(*) FROM (\(Self.boardHistoryUnsettledSQL)) WHERE \(unheld)")?.int(0) ?? 0
        let doing = "CASE WHEN json_valid(snapshot) THEN json_extract(snapshot, '$.doing') END"
        let repeated = try db.first("""
            SELECT COUNT(*) FROM (SELECT fields, \(doing) AS doing, LAG(\(doing)) OVER w AS before, LEAD(id) OVER w AS next_id
                                  FROM main.board_history WINDOW w AS (PARTITION BY row_id ORDER BY id))
            WHERE fields = 'doing' AND doing = before AND next_id IS NOT NULL
            """)?.int(0) ?? 0
        guard unsettled + repeated > 0 else {
            try setSetting(Self.boardHistorySettledVersion, key: Self.boardHistorySettledKey, owner: nil)
            return .init(before: before, after: before, backup: nil, seconds: Date().timeIntervalSince(started))
        }
        // The copy first. If it cannot be made, nothing changes (the next opening tries again).
        let backup = try backupNow()
        let after: Int
        do { after = try db.transaction {
            // The entries to keep, in a temporary table (outside the memory folder), then the history is emptied in
            // one step and refilled with them, ids unchanged. Far fewer writes than deleting 95% of it row by row.
            try db.exec("DROP TABLE IF EXISTS temp.board_history_settled")
            try db.exec("CREATE TEMP TABLE board_history_settled AS SELECT id, row_id, at, fields, snapshot FROM (\(Self.boardHistoryUnsettledSQL)) WHERE NOT (\(unheld))")
            try db.exec("""
                DELETE FROM temp.board_history_settled WHERE id IN (
                    SELECT id FROM (SELECT id, fields, \(doing) AS doing, LAG(\(doing)) OVER w AS before, LEAD(id) OVER w AS next_id
                                    FROM temp.board_history_settled WINDOW w AS (PARTITION BY row_id ORDER BY id))
                    WHERE fields = 'doing' AND doing = before AND next_id IS NOT NULL)
                """)
            let kept = Int(try db.first("SELECT COUNT(*) FROM temp.board_history_settled")?.int(0) ?? 0)
            // Every row keeps at least its newest entry; anything else means the statements above went wrong: change nothing.
            let rows = try db.first("SELECT COUNT(DISTINCT row_id) FROM main.board_history")?.int(0) ?? 0
            let keptRows = try db.first("SELECT COUNT(DISTINCT row_id) FROM temp.board_history_settled")?.int(0) ?? 0
            guard kept > 0 || before == 0, keptRows == rows, kept <= before else {
                throw DeckMemoryError(.io, "The board history settle kept \(kept) of \(before) entries for \(keptRows) of \(rows) rows; nothing was changed.")
            }
            try db.exec("DELETE FROM main.board_history")
            try db.exec("INSERT INTO main.board_history (id, row_id, at, fields, snapshot) SELECT id, row_id, at, fields, snapshot FROM temp.board_history_settled ORDER BY id")
            try db.exec("DROP TABLE temp.board_history_settled")
            try setSetting(Self.boardHistorySettledVersion, key: Self.boardHistorySettledKey, owner: nil)
            return kept
        } } catch {
            try? db.exec("DROP TABLE IF EXISTS temp.board_history_settled")
            try? setSetting("tried-\(tries + 1)", key: Self.boardHistorySettledKey, owner: nil)
            throw error
        }
        return .init(before: before, after: after, backup: backup, seconds: Date().timeIntervalSince(started))
    }
    /// What one update would change on a row (`existing`, nil for a new row), worked out without writing.
    /// `fields` is empty when the update says nothing new. Throws `proofRequired` before anything is written.
    func planBoard(_ update: DeckMemoryBoardUpdate, existing: DeckMemoryBoardRow?, at: Date) throws -> (row: DeckMemoryBoardRow, fields: [String]) {
        guard !update.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeckMemoryError(.invalid, "A board row needs an id.") }
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
        guard !fields.isEmpty else { return (row, []) }
        row.labels = labels; row.updatedAt = at
        return (row, fields)
    }
    /// Writes a planned row and its history entry. Inside the caller's transaction.
    private func applyBoard(_ row: DeckMemoryBoardRow, fields: [String], at: Date) throws {
        try db.run("""
            INSERT INTO board (id, kind, title, owner, project, session, agent, doing, last_result, waiting, state, proof, updated, archived, hand, job)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, owner = excluded.owner, project = excluded.project, session = excluded.session,
                agent = excluded.agent, doing = excluded.doing, last_result = excluded.last_result, waiting = excluded.waiting, state = excluded.state,
                proof = excluded.proof, updated = excluded.updated, archived = NULL, hand = excluded.hand, job = excluded.job
            """, [.text(row.id), .text(row.kind.rawValue), .text(row.title), .text(row.labels.owner.key), .optional(row.labels.project), .optional(row.labels.session),
                  .optional(row.labels.agent), .text(row.doing), .text(row.lastResult), .text(row.waitingForUser), .optional(row.state?.rawValue),
                  .text(row.proof), .date(at), .optional(row.labels.hand), .optional(row.labels.job)])
        try recordBoard(row, fields: fields, at: at)
    }
    public func updateBoard(_ update: DeckMemoryBoardUpdate) async throws -> DeckMemoryBoardRow {
        guard !update.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeckMemoryError(.invalid, "A board row needs an id.") }
        let at = now()
        let planned = try planBoard(update, existing: try boardRow(id: update.id), at: at)
        guard !planned.fields.isEmpty else { return planned.row }
        try db.transaction { try applyBoard(planned.row, fields: planned.fields, at: at) }
        post(.board, planned.row.labels.owner, planned.row.id)
        return planned.row
    }
    /// Several board changes, and rows leaving the board, in ONE transaction: one journal and one sync for all of
    /// them. 2 Nov 2026: a session's status change rewrote three rows (the session, its project, its seat), each in
    /// its own fully synced transaction, and that was most of the app's disk writes (about 0.8 to 2.2 MB/s).
    /// An update that says nothing new writes nothing, and when nothing changed no transaction is opened at all.
    /// One that is refused (no id, `proofRequired`) is left out, the rest are still written, then the first refusal is thrown.
    public func writeBoard(_ updates: [DeckMemoryBoardUpdate], archive: [String]) async throws {
        let at = now()
        enum Step { case update(DeckMemoryBoardRow, [String]), archive(DeckMemoryBoardRow) }
        var steps: [Step] = [], current: [String: DeckMemoryBoardRow] = [:], refused: Error?
        for update in updates {
            do {
                let existing = try current[update.id] ?? boardRow(id: update.id)
                let planned = try planBoard(update, existing: existing, at: at)
                guard !planned.fields.isEmpty else { continue }
                current[update.id] = planned.row; steps.append(.update(planned.row, planned.fields))
            } catch let error as DeckMemoryError where error.code != .io { refused = refused ?? error }
        }
        for id in archive {
            // A row that is not on the board (or has left it already) has nothing to archive.
            guard var row = try current[id] ?? boardRow(id: id), row.archivedAt == nil else { continue }
            row.archivedAt = at; current[id] = row; steps.append(.archive(row))
        }
        if !steps.isEmpty {
            try db.transaction {
                for step in steps {
                    switch step {
                    case .update(let row, let fields): try applyBoard(row, fields: fields, at: at)
                    case .archive(let row):
                        try db.run("UPDATE board SET archived = ? WHERE id = ?", [.date(at), .text(row.id)])
                        try recordBoard(row, fields: ["archived"], at: at)
                    }
                }
            }
            for step in steps {
                switch step { case .update(let row, _), .archive(let row): post(.board, row.labels.owner, row.id) }
            }
        }
        if let refused { throw refused }
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
        try await boardChanges(since: since, owner: owner, limit: Self.boardChangesRead)
    }
    /// At most this many changes are read for one message.
    static let boardChangesRead = 2_000
    /// The NEWEST `limit` changes after `since`, oldest first (2 Nov: it read the oldest 2,000, so a flood of
    /// working/idle flips hid the newest real changes from "what changed since your last message").
    func boardChanges(since: Date, owner: DeckMemoryOwner?, limit: Int) async throws -> [DeckMemoryBoardChange] {
        var sql = "SELECT h.id, h.at, h.fields, h.snapshot FROM board_history h JOIN board ON board.id = h.row_id WHERE h.at > ?"
        var args: [DeckMemorySQL] = [.date(since)]
        if let owner, let clause = Self.scopeClause(owner) {
            // The row's CURRENT labels decide who sees its history.
            sql += " AND " + clause.sql.replacingOccurrences(of: "project", with: "board.project").replacingOccurrences(of: "owner", with: "board.owner")
            args += clause.args
        }
        return try db.rows(sql + " ORDER BY h.id DESC LIMIT ?", args + [.int(Int64(max(0, limit)))]).reversed().compactMap { row in
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
