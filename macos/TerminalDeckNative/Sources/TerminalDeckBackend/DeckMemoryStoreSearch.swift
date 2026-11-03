import Foundation
import TerminalDeckNativeCore

// Search: exact words through FTS5, and matching by meaning through on-device embeddings.
extension DeckMemoryStore {
    /// The words of a question, as FTS5 wants them: each word quoted, the last one also matching longer words.
    static func words(_ text: String) -> [String] {
        var words: [String] = [], current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { current.append(character) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        return Array(words.prefix(24))
    }
    /// Words that say nothing about what is being looked for. They are left out of a word search (unless the
    /// question is made of nothing else), so "what is the server password" does not match every note with "is" in it.
    static let fillerWords: Set<String> = ["a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "by", "for", "from", "with", "about",
        "into", "as", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "doing", "done", "have", "has", "had", "having",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his", "she", "her", "it", "its", "they", "them", "their", "this", "that",
        "these", "those", "what", "which", "who", "whom", "whose", "when", "where", "why", "how", "can", "could", "should", "would", "will", "shall",
        "may", "might", "must", "not", "no", "so", "than", "then", "there", "here", "any", "all", "some", "just", "still", "now", "also", "too",
        "very", "up", "out", "please", "let", "lets", "s", "t", "d", "ll", "re", "ve", "m"]
    /// The words a word search looks for: the question's words without the filler, or all of them when only filler is left.
    static func searchWords(_ text: String) -> [String] {
        let all = words(text), meaningful = all.filter { !fillerWords.contains($0) }
        return meaningful.isEmpty ? all : meaningful
    }
    static func matchQuery(_ words: [String], any: Bool) -> String {
        words.enumerated().map { index, word in "\"" + word + "\"" + (index == words.count - 1 ? "*" : "") }.joined(separator: any ? " OR " : " ")
    }
    private func scope(_ query: DeckMemorySearchQuery, prefix: String = "") -> (sql: String, args: [DeckMemorySQL]) {
        var clauses: [String] = [], args: [DeckMemorySQL] = []
        if let owner = query.owner { clauses.append(prefix + "owner = ?"); args.append(.text(owner.key)) }
        if let project = query.project {
            let clause = Self.projectClause(project)
            clauses.append(clause.sql.replacingOccurrences(of: "project", with: prefix + "project").replacingOccurrences(of: "owner", with: prefix + "owner"))
            args += clause.args
        }
        if let session = query.session { clauses.append(prefix + "session = ?"); args.append(.text(session)) }
        if let agent = query.agent { clauses.append(prefix + "agent = ?"); args.append(.text(agent)) }
        if let kinds = query.kinds {
            clauses.append(prefix + "kind IN (" + (kinds.isEmpty ? "''" : kinds.map { _ in "?" }.joined(separator: ", ")) + ")")
            args += kinds.map { .text($0.rawValue) }
        }
        if let since = query.since { clauses.append(prefix + "at >= ?"); args.append(.date(since)) }
        if let until = query.until { clauses.append(prefix + "at <= ?"); args.append(.date(until)) }
        // 0 current, 1 archived, 2 replaced. Replaced notes are shown only when asked for, and always below the current ones.
        if !query.includeArchived { clauses.append(prefix + (query.includeReplaced ? "archived IN (0, 2)" : "archived = 0")) }
        return (clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND "), args)
    }
    /// Date, type, path and the full labels for one hit, from the table that owns it.
    private func hit(kind: DeckMemorySearchKind, ref: String, title: String, snippet: String, score: Double, by: DeckMemorySearchMode, archived: Bool,
                     fallback: DeckMemoryLabels) throws -> DeckMemorySearchHit {
        switch kind {
        case .note:
            if let row = try noteRow(ref) {
                let note = note(row)
                var standing: String?
                if note.status != .current {
                    let when = (note.validUntil ?? note.archivedAt).map { " on " + DeckMemoryFiles.day($0) } ?? ""
                    let other = try note.supersededBy.flatMap { try noteRow($0) }.map { "“" + $0.text(2) + "”" }
                    switch note.status {
                    case .superseded: standing = "replaced" + when + (other.map { " by " + $0 } ?? "")
                    case .merged: standing = "merged" + when + (other.map { " into " + $0 } ?? "")
                    case .history: standing = "an earlier state; current is " + (other ?? "a newer note")
                    case .rewound: standing = "set aside by a rewind" + when + "; not current"
                    default: standing = "archived" + when
                    }
                }
                return .init(kind: kind, ref: ref, title: note.title, snippet: snippet, labels: note.labels, path: note.path, score: score, matchedBy: by, archived: note.isArchived, standing: standing)
            }
        case .diary:
            if let id = Int64(ref), let row = try db.first("SELECT \(Self.diaryColumns) FROM diary WHERE id = ?", [.int(id)]) {
                let entry = diaryEntry(row)
                // From the row's author, the same rule the Diary list uses: a builder's test is never "You".
                let who = entry.writerName()
                // Still findable, and said plainly: this part of the conversation was rewound.
                let standing = entry.rewoundAt.map { "rewound on " + DeckMemoryFiles.day($0) + "; no longer part of the conversation" }
                return .init(kind: kind, ref: ref, title: who + ", " + DeckMemoryFiles.day(entry.at), snippet: snippet, labels: entry.labels, path: nil, score: score, matchedBy: by, standing: standing)
            }
        case .topic:
            // A handoff is kept with its topic and is found as a topic hit: its ref ends in "#handoff:<id>".
            if let mark = ref.range(of: "#handoff:"), let row = try handoffRow(String(ref[mark.upperBound...])) {
                let found = handoff(row)
                return .init(kind: kind, ref: ref, title: "Handoff: " + found.title, snippet: snippet, labels: found.labels, path: found.path, score: score,
                             matchedBy: by, archived: found.isArchived, standing: found.isArchived ? "archived on " + DeckMemoryFiles.day(found.archivedAt ?? found.updatedAt) : nil)
            }
            // A role seat's key itself contains "/": the topic id is what follows the LAST one.
            if let slash = ref.lastIndex(of: "/"), let owner = DeckMemoryOwner(key: String(ref[..<slash])), let row = try topicRow(owner, String(ref[ref.index(after: slash)...])) {
                let topic = topic(row)
                return .init(kind: kind, ref: ref, title: topic.title, snippet: snippet, labels: topic.labels, path: topic.path, score: score, matchedBy: by, archived: !topic.open)
            }
        case .card: return .init(kind: kind, ref: ref, title: "Card", snippet: snippet, labels: fallback, path: fallback.owner.cardPath, score: score, matchedBy: by)
        case .playbook: return .init(kind: kind, ref: ref, title: "Playbook", snippet: snippet, labels: fallback, path: fallback.owner.playbookPath, score: score, matchedBy: by)
        }
        return .init(kind: kind, ref: ref, title: title, snippet: snippet, labels: fallback, path: nil, score: score, matchedBy: by, archived: archived)
    }
    private func labels(_ row: DeckMemoryRow, from offset: Int, kind: String) -> DeckMemoryLabels {
        .init(owner: DeckMemoryOwner(key: row.text(offset)) ?? .hoot, project: row.string(offset + 1), session: row.string(offset + 2),
              agent: row.string(offset + 3), date: now(), type: kind)
    }

    /// `partial`: nothing held all the words, so these hits hold only some of them (a weaker kind of word match).
    func wordHits(_ query: DeckMemorySearchQuery, limit: Int) throws -> [DeckMemorySearchHit] { try wordSearch(query, limit: limit).hits }
    func wordSearch(_ query: DeckMemorySearchQuery, limit: Int) throws -> (hits: [DeckMemorySearchHit], partial: Bool) {
        let words = Self.searchWords(query.text)
        guard !words.isEmpty else { return ([], false) }
        var partial = false
        let scope = scope(query)
        var rows: [DeckMemoryRow] = []
        if db.hasFTS {
            let sql = "SELECT kind, ref, owner, project, session, agent, archived, title, snippet(search, 8, '', '', ' … ', 18), bm25(search, 0, 0, 0, 0, 0, 0, 0, 3.0, 1.0), substr(body, 1, 200) FROM search WHERE search MATCH ?\(scope.sql) ORDER BY bm25(search, 0, 0, 0, 0, 0, 0, 0, 3.0, 1.0) LIMIT ?"
            rows = try db.rows(sql, [.text(Self.matchQuery(words, any: false))] + scope.args + [.int(Int64(limit))])
            // All the words together found nothing: any of them is better than an empty page.
            if rows.isEmpty, words.count > 1 {
                rows = try db.rows(sql, [.text(Self.matchQuery(words, any: true))] + scope.args + [.int(Int64(limit))]); partial = !rows.isEmpty
            }
        } else {
            let like = words.map { _ in "(title LIKE ? ESCAPE '!' OR body LIKE ? ESCAPE '!')" }.joined(separator: " AND ")
            let patterns: [DeckMemorySQL] = words.flatMap { word -> [DeckMemorySQL] in let p = "%" + Self.likeEscaped(word) + "%"; return [.text(p), .text(p)] }
            rows = try db.rows("SELECT kind, ref, owner, project, session, agent, archived, title, substr(body, 1, 200), 0.0, substr(body, 1, 200) FROM search WHERE \(like)\(scope.sql) ORDER BY rowid DESC LIMIT ?",
                               patterns + scope.args + [.int(Int64(limit))])
        }
        let hits: [DeckMemorySearchHit] = try rows.compactMap { row in
            guard let kind = DeckMemorySearchKind(rawValue: row.text(0)) else { return nil }
            var snippet = row.text(8).trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty { snippet = row.text(10).trimmingCharacters(in: .whitespacesAndNewlines) }
            // bm25 is smaller-is-better and negative: turn it into a plain "bigger is better" score.
            return try hit(kind: kind, ref: row.text(1), title: row.text(7), snippet: snippet.replacingOccurrences(of: "\n", with: " "),
                           score: -(row.double(9) ?? 0), by: .words, archived: row.int(6) != 0, fallback: labels(row, from: 2, kind: kind.rawValue))
        }
        return (hits, partial)
    }

    /// The vectors one search compares, read once for the question and all its parts (they share one scope).
    struct MeaningPieces: Sendable {
        struct Piece: Sendable {
            let kind: String, ref: String, owner: String, project: String?, session: String?, agent: String?
            let archived: Bool, vector: Data
        }
        let pieces: [Piece]
    }
    /// Per window. The diary (every message, up to 12 pieces each) has its own window of its newest pieces;
    /// notes, topics, cards and playbooks have theirs, so weeks of talk never push a current note out of reach.
    static let meaningCandidates = 20_000
    /// How long a search waits for its question's vector before answering by words alone.
    static let questionVectorSeconds: Double = 5
    func meaningPieces(_ query: DeckMemorySearchQuery) throws -> MeaningPieces? {
        guard let embedder, !embeddingOff, !closed else { return nil }
        let scope = scope(query)
        var pieces: [MeaningPieces.Piece] = []
        for window in ["kind != 'diary'", "kind = 'diary'"] {
            let rows = try db.rows("SELECT kind, ref, owner, project, session, agent, archived, vector FROM embeddings WHERE model = ? AND \(window)\(scope.sql) ORDER BY rowid DESC LIMIT ?",
                                   [.text(embedder.model)] + scope.args + [.int(Int64(Self.meaningCandidates))])
            pieces += rows.compactMap { row in
                row.data(7).map { .init(kind: row.text(0), ref: row.text(1), owner: row.text(2), project: row.string(3), session: row.string(4),
                                        agent: row.string(5), archived: row.int(6) != 0, vector: $0) }
            }
        }
        return .init(pieces: pieces)
    }
    /// The best piece per text at or above the floor, best first. A long text is stored as several pieces; the
    /// piece that fits best speaks for the whole. Works on a copy, away from the store.
    static func meaningScores(_ pieces: [MeaningPieces.Piece], wanted: [Float], floor: Double) -> [(piece: MeaningPieces.Piece, score: Double)] {
        var best: [String: (piece: MeaningPieces.Piece, score: Double)] = [:]
        for piece in pieces {
            let score = DeckMemoryVectors.cosine(wanted, DeckMemoryVectors.vector(piece.vector))
            guard score >= floor else { continue }
            let key = piece.kind + ":" + piece.ref
            if score > (best[key]?.score ?? -1) { best[key] = (piece, score) }
        }
        return best.values.sorted { $0.score == $1.score ? $0.piece.ref < $1.piece.ref : $0.score > $1.score }
    }
    /// `given`: the vectors already read for this search (its other parts ask the same scope).
    func meaningHits(_ query: DeckMemorySearchQuery, limit: Int, pieces given: MeaningPieces? = nil) async throws -> [DeckMemorySearchHit]? {
        // 30 Oct: the question's own vector has a budget too (the model may still be loading on a busy Mac); without
        // it the search answers by words and says that meaning was not available.
        guard let embedder, !embeddingOff else { return nil }
        let text = query.text
        guard let wanted = await BackendMCPCallBudget.within(Self.questionVectorSeconds, { await embedder.vector(for: text) }) ?? nil else { return nil }
        guard let candidates = try given ?? meaningPieces(query) else { return [] }
        // The comparing runs off the store, so diary appends and board updates do not wait for a search.
        let floor = embedder.meaningFloor
        let scored = await Task.detached(priority: .userInitiated) { Self.meaningScores(candidates.pieces, wanted: wanted, floor: floor) }.value
        guard !closed else { return [] }
        return try scored.prefix(limit).compactMap { item in
            guard let kind = DeckMemorySearchKind(rawValue: item.piece.kind) else { return nil }
            let ref = item.piece.ref
            let text = try db.first("SELECT s.title, substr(s.body, 1, 240) FROM search_map m JOIN search s ON s.rowid = m.row WHERE m.kind = ? AND m.ref = ?", [.text(kind.rawValue), .text(ref)])
            let fallback = DeckMemoryLabels(owner: DeckMemoryOwner(key: item.piece.owner) ?? .hoot, project: item.piece.project, session: item.piece.session,
                                            agent: item.piece.agent, date: now(), type: kind.rawValue)
            return try hit(kind: kind, ref: ref, title: text?.text(0) ?? "", snippet: (text?.text(1) ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces),
                           score: item.score, by: .meaning, archived: item.piece.archived, fallback: fallback)
        }
    }

    /// Words are the base; meaning is a second list. The two are merged by rank (1 / (rank + 1) from each list),
    /// so an exact word hit can come first with no meaning match at all, and agreement between the two lifts a hit.
    /// One search, in four steps: (1) words and meaning, merged by rank; (2) a question with several parts also
    /// searches each part and keeps each part's best answer in the top; (3) near-duplicates are pushed down so the top
    /// covers different things; (4) a short diary reply comes with the messages around it.
    public func search(_ query: DeckMemorySearchQuery) async throws -> DeckMemorySearchResult {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .init(hits: [], usedMeaning: false) }
        let limit = max(1, min(query.limit, 200)), pool = max(limit * 3, 30)
        // The vectors are read once here, not again for each part of the question.
        let pieces = query.mode == .words ? nil : try meaningPieces(query)
        let whole = try await rankedHits(query, pool: pool, pieces: pieces)
        var hits = whole.hits, usedMeaning = whole.usedMeaning, partBests: [String] = []
        let parts = Self.questionParts(text)
        if parts.count >= 2 {
            var lists = [hits]
            for part in parts {
                var asked = query; asked.text = part
                let found = try await rankedHits(asked, pool: pool, pieces: pieces)
                lists.append(found.hits); usedMeaning = usedMeaning || found.usedMeaning
                if let best = found.hits.first(where: { $0.standing == nil }), !partBests.contains(best.id) { partBests.append(best.id) }
            }
            hits = Self.mergeByRank(lists)
        }
        hits = try diversified(hits)
        var top = Array(hits.prefix(limit))
        // Each part's best answer stays in the top, in place of the lowest current hit that is not one.
        for id in partBests where !top.contains(where: { $0.id == id }) {
            guard let hit = hits.first(where: { $0.id == id }) else { continue }
            if top.count >= limit {
                guard let drop = top.lastIndex(where: { $0.standing == nil && !partBests.contains($0.id) }) else { continue }
                top.remove(at: drop)
            }
            top.insert(hit, at: top.firstIndex(where: { $0.standing != nil }) ?? top.count)
        }
        return .init(hits: try withContext(top), usedMeaning: usedMeaning, notice: whole.notice)
    }

    /// Words and meaning for one question, merged by rank, current first. The whole list, not cut to a limit.
    func rankedHits(_ query: DeckMemorySearchQuery, pool: Int, pieces: MeaningPieces? = nil) async throws -> (hits: [DeckMemorySearchHit], usedMeaning: Bool, notice: String?) {
        var lists: [[DeckMemorySearchHit]] = [], usedMeaning = false, notice: String?, partialWords = false
        if query.mode != .meaning { let found = try wordSearch(query, limit: pool); lists.append(found.hits); partialWords = found.partial }
        if query.mode != .words {
            if let byMeaning = try await meaningHits(query, limit: pool, pieces: pieces) {
                usedMeaning = true; lists.append(byMeaning)
            } else {
                notice = "Matching by meaning is not available on this Mac right now, so these are word matches."
                if query.mode == .meaning { lists.append(try wordHits(query, limit: pool)) }
            }
        }
        // Only a match on ALL the words counts as "the words already answered". A hit holding just some of them is
        // weak evidence: meaning is then as good a witness as the words, and its hits are not held to the higher bar.
        if query.mode == .both, lists.count == 2, !lists[0].isEmpty, !partialWords {
            // The words already answered: a match by meaning alone has to be a clear one to be shown beside them.
            // (Seen in the dev copy: a two-word query pulled in unrelated diary rows at 0.27 to 0.30.)
            let byWords = Set(lists[0].map(\.id))
            let beside = embedder?.meaningFloorBesideWords ?? 1
            lists[1] = lists[1].filter { byWords.contains($0.id) || $0.score >= beside }
        }
        var merged: [String: DeckMemorySearchHit] = [:], score: [String: Double] = [:], order: [String] = []
        for (index, list) in lists.enumerated() {
            // Merged by rank: 1 / (rank + 1) from each list. Hits holding only some of the words count half.
            let weight = index == 0 && partialWords && query.mode == .both ? 0.5 : 1.0
            for (rank, hit) in list.enumerated() {
                score[hit.id, default: 0] += weight / Double(rank + 1)
                if var seen = merged[hit.id] { if seen.matchedBy != hit.matchedBy { seen.matchedBy = .both }; merged[hit.id] = seen }
                else { merged[hit.id] = hit; order.append(hit.id) }
            }
        }
        var hits = order.compactMap { id -> DeckMemorySearchHit? in
            guard var hit = merged[id] else { return nil }
            hit.score = score[id] ?? 0; return hit
        }
        // Current first, then what was replaced; inside each, best rank first. Equal ranks keep their first-seen order.
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        hits.sort { a, b in
            if (a.standing == nil) != (b.standing == nil) { return a.standing == nil }
            if a.score != b.score { return a.score > b.score }
            return (position[a.id] ?? 0) < (position[b.id] ?? 0)
        }
        return (hits, usedMeaning, notice)
    }

    /// Lists merged by rank (1 / (rank + 1) from each), current first.
    static func mergeByRank(_ lists: [[DeckMemorySearchHit]]) -> [DeckMemorySearchHit] {
        var merged: [String: DeckMemorySearchHit] = [:], score: [String: Double] = [:], order: [String] = []
        for list in lists {
            for (rank, hit) in list.enumerated() {
                score[hit.id, default: 0] += 1.0 / Double(rank + 1)
                if var seen = merged[hit.id] { if seen.matchedBy != hit.matchedBy { seen.matchedBy = .both }; merged[hit.id] = seen }
                else { merged[hit.id] = hit; order.append(hit.id) }
            }
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.compactMap { id -> DeckMemorySearchHit? in var hit = merged[id]; hit?.score = score[id] ?? 0; return hit }.sorted { a, b in
            if (a.standing == nil) != (b.standing == nil) { return a.standing == nil }
            if a.score != b.score { return a.score > b.score }
            return (position[a.id] ?? 0) < (position[b.id] ?? 0)
        }
    }

    // MARK: Several parts, several different answers

    /// A question that asks for several things ("what waits for Vishal and when were the CRM questions answered") in
    /// its parts. Only when every part carries at least two real words, so "sign and upload builds" stays one question.
    static func questionParts(_ text: String) -> [String] {
        guard let splitter = try? NSRegularExpression(pattern: #"(?i)\s*(?:[;,]\s*(?:and\s+)?|\s+(?:and also|as well as|and|plus|versus|vs\.?|&)\s+)"#) else { return [] }
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: " ?!.\n\t"))
        var parts: [String] = [], start = clean.startIndex
        for match in splitter.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)) {
            guard let range = Range(match.range, in: clean) else { continue }
            parts.append(String(clean[start..<range.lowerBound])); start = range.upperBound
        }
        parts.append(String(clean[start...]))
        let lead = try? NSRegularExpression(pattern: #"(?i)^\s*(?:both|either)\s+"#)
        let kept = parts.map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return lead?.stringByReplacingMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed), withTemplate: "") ?? trimmed
        }
        guard kept.count >= 2, kept.allSatisfy({ words($0).filter { !fillerWords.contains($0) }.count >= 2 }) else { return [] }
        return Array(kept.prefix(4))
    }

    /// The text a hit stands for, as its meaningful words (title and the start of the body).
    private func meaningfulWords(_ hit: DeckMemorySearchHit) throws -> Set<String> {
        let row = try db.first("SELECT s.title, substr(s.body, 1, 2000) FROM search_map m JOIN search s ON s.rowid = m.row WHERE m.kind = ? AND m.ref = ?",
                               [.text(hit.kind.rawValue), .text(hit.ref)])
        return Set(Self.words((row?.text(0) ?? hit.title) + " " + (row?.text(1) ?? hit.snippet)).filter { !Self.fillerWords.contains($0) })
    }
    private func firstVector(_ hit: DeckMemorySearchHit) throws -> [Float]? {
        guard let embedder else { return nil }
        return try db.first("SELECT vector FROM embeddings WHERE kind = ? AND ref = ? AND model = ? ORDER BY piece LIMIT 1",
                            [.text(hit.kind.rawValue), .text(hit.ref), .text(embedder.model)])?.data(0).map(DeckMemoryVectors.vector)
    }
    static let duplicateWordOverlap = 0.5
    /// Near-duplicates pushed down (a maximal-marginal-relevance pass with a fixed bar): going down the list, a current
    /// hit that says what an earlier kept hit already says (half or more of the same words, or a near-identical
    /// meaning) moves below the different ones. Nothing is dropped; replaced notes keep their place after the current ones.
    func diversified(_ hits: [DeckMemorySearchHit]) throws -> [DeckMemorySearchHit] {
        let current = hits.filter { $0.standing == nil }, replaced = hits.filter { $0.standing != nil }
        guard current.count > 1 else { return hits }
        var kept: [DeckMemorySearchHit] = [], pushed: [DeckMemorySearchHit] = [], seen: [(words: Set<String>, vector: [Float]?)] = []
        let bar = embedder?.duplicateSimilarity ?? 1
        for hit in current {
            let words = try meaningfulWords(hit), vector = try firstVector(hit)
            let duplicate = seen.contains { earlier in
                let union = words.union(earlier.words).count
                if union > 0, Double(words.intersection(earlier.words).count) / Double(union) >= Self.duplicateWordOverlap { return true }
                if let vector, let other = earlier.vector, DeckMemoryVectors.cosine(vector, other) >= bar { return true }
                return false
            }
            if duplicate { pushed.append(hit) } else { kept.append(hit); seen.append((words, vector)) }
        }
        return kept + pushed + replaced
    }

    // MARK: A short reply comes with its neighbours

    static let shortReply = 80
    /// A diary hit whose own text is short ("ok, do that", "yes, the second one") gets the message just before and the one
    /// just after it in the same conversation (live rows only), so the hit means something when read on its own.
    func withContext(_ hits: [DeckMemorySearchHit]) throws -> [DeckMemorySearchHit] {
        try hits.map { hit in
            guard hit.kind == .diary, let id = Int64(hit.ref),
                  let row = try db.first("SELECT \(Self.diaryColumns) FROM diary WHERE id = ?", [.int(id)]) else { return hit }
            let entry = diaryEntry(row)
            guard entry.text.trimmingCharacters(in: .whitespacesAndNewlines).count < Self.shortReply else { return hit }
            var scope = "owner = ?", args: [DeckMemorySQL] = [.text(entry.labels.owner.key)]
            if let conversation = entry.conversation { scope = "conversation = ?"; args = [.text(conversation)] }
            else if let session = entry.labels.session { scope = "session = ?"; args = [.text(session)] }
            let live = " AND rewound IS NULL AND role IN ('user', 'assistant')"
            let before = try db.first("SELECT \(Self.diaryColumns) FROM diary WHERE \(scope) AND id < ?\(live) ORDER BY id DESC LIMIT 1", args + [.int(id)]).map(diaryEntry)
            let after = try db.first("SELECT \(Self.diaryColumns) FROM diary WHERE \(scope) AND id > ?\(live) ORDER BY id ASC LIMIT 1", args + [.int(id)]).map(diaryEntry)
            func line(_ label: String, _ other: DeckMemoryDiaryEntry?) -> String? {
                guard let other else { return nil }
                let text = other.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                return label + " (" + other.writerName() + "): " + (text.count > 300 ? String(text.prefix(300)) + " …" : text)
            }
            let around = [line("Just before", before), line("Just after", after)].compactMap { $0 }
            guard !around.isEmpty else { return hit }
            var expanded = hit; expanded.context = around.joined(separator: "\n")
            return expanded
        }
    }

    // MARK: Making the vectors (in the background, a few at a time)

    func kickEmbedding() {
        guard embedTask == nil, embedder != nil, !embeddingOff, !closed else { return }
        embedTask = Task { [weak self] in await self?.embedPending() }
    }
    /// Tests: wait until every queued text has its vector.
    func finishEmbedding() async {
        kickEmbedding()
        while let task = embedTask { await task.value; if embedTask == nil { kickEmbeddingIfQueued() } }
    }
    private func kickEmbeddingIfQueued() {
        if (try? db.first("SELECT 1 FROM embed_queue LIMIT 1")) != nil { kickEmbedding() }
    }
    /// Long text is cut into pieces of about 900 characters at paragraph ends before a vector is made of each:
    /// one vector for a 10,000-character message finds nothing.
    static let pieceCharacters = 900
    static let maxPieces = 12
    static func pieces(_ text: String) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > pieceCharacters else { return clean.isEmpty ? [] : [clean] }
        var pieces: [String] = [], current = ""
        func flush() { let piece = current.trimmingCharacters(in: .whitespacesAndNewlines); if !piece.isEmpty { pieces.append(piece) }; current = "" }
        for paragraph in clean.components(separatedBy: "\n\n") {
            if current.count + paragraph.count + 2 > pieceCharacters, !current.isEmpty { flush() }
            if paragraph.count > pieceCharacters {
                // One very long paragraph: cut at line ends, then by length.
                for line in paragraph.components(separatedBy: "\n") {
                    var rest = Substring(line)
                    while !rest.isEmpty {
                        let room = max(1, pieceCharacters - current.count)
                        current += rest.prefix(room) + (rest.count <= room ? "\n" : ""); rest = rest.dropFirst(room)
                        if current.count >= pieceCharacters { flush() }
                    }
                }
            } else { current += paragraph + "\n\n" }
        }
        flush()
        return Array(pieces.prefix(maxPieces))
    }
    /// Every indexed text that has no vector from the current model is queued for one: texts written while memory
    /// ran without a model (or while the model could not make vectors) catch up. Runs once per opening, in the
    /// background after the start, as one statement over the index; the vectors themselves are made a few at a time.
    /// Same rule as a model change: diary rows only for the person's and the AI's words of 12 characters or more,
    /// and nothing for an empty text. Returns how many were queued.
    @discardableResult func queueMissingVectors() throws -> Int {
        guard let embedder else { return 0 }
        try db.run("""
            INSERT OR IGNORE INTO embed_queue (kind, ref)
            SELECT m.kind, m.ref FROM search_map m JOIN search s ON s.rowid = m.row
            WHERE (length(s.title) > 0 OR length(s.body) > 0)
              AND NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.kind = m.kind AND e.ref = m.ref AND e.model = ?)
              AND (m.kind != 'diary' OR m.ref IN (SELECT CAST(id AS TEXT) FROM diary WHERE role IN ('user', 'assistant') AND length(text) >= 12))
            """, [.text(embedder.model)])
        return db.changes
    }
    private func embedPending() async {
        defer { embedTask = nil }
        guard let embedder else { return }
        if !missingQueued { missingQueued = true; _ = try? queueMissingVectors() }
        while !closed, !Task.isCancelled {
            guard let batch = try? db.rows("SELECT kind, ref FROM embed_queue LIMIT 16"), !batch.isEmpty else { return }
            for item in batch {
                let kind = item.text(0), ref = item.text(1)
                guard let source = try? db.first("SELECT s.owner, s.project, s.session, s.agent, s.archived, s.title, s.body, s.at FROM search_map m JOIN search s ON s.rowid = m.row WHERE m.kind = ? AND m.ref = ?", [.text(kind), .text(ref)]) else {
                    _ = try? db.run("DELETE FROM embed_queue WHERE kind = ? AND ref = ?", [.text(kind), .text(ref)]); continue
                }
                let title = source.text(5), pieces = Self.pieces(source.text(6))
                let texts = pieces.isEmpty ? (title.isEmpty ? [] : [title]) : pieces.enumerated().map { $0 == 0 && !title.isEmpty ? title + "\n" + $1 : $1 }
                var vectors: [[Float]] = []
                for text in texts {
                    guard let vector = await embedder.vector(for: text) else {
                        // This Mac cannot make vectors: stop asking, keep the queue, and let search use words.
                        embeddingOff = true; return
                    }
                    vectors.append(vector)
                    guard !closed else { return }
                }
                _ = try? db.run("DELETE FROM embeddings WHERE kind = ? AND ref = ?", [.text(kind), .text(ref)])
                for (piece, vector) in vectors.enumerated() {
                    _ = try? db.run("INSERT OR REPLACE INTO embeddings (kind, ref, piece, owner, project, session, agent, archived, at, model, vector) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        [.text(kind), .text(ref), .int(Int64(piece)), .text(source.text(0)), .optional(source.string(1)), .optional(source.string(2)), .optional(source.string(3)),
                         .int(source.int(4)), .optional(source.date(7)), .text(embedder.model), .blob(DeckMemoryVectors.data(vector))])
                }
                _ = try? db.run("DELETE FROM embed_queue WHERE kind = ? AND ref = ?", [.text(kind), .text(ref)])
                await Task.yield()
            }
        }
    }
}
