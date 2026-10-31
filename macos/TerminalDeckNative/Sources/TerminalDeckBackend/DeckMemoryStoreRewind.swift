import Foundation
import TerminalDeckNativeCore

// Rewind: the conversation goes back to a chosen message. What came after is set aside, never deleted,
// and one call puts it back.
extension DeckMemoryStore {
    /// What a rewind did to topics, kept so the undo is exact.
    private struct RewindUndo: Codable {
        /// Topics first written in the rewound part: marked "rewound" (no longer open).
        var setAside: [String] = []
        /// Topics that existed before and were updated in the rewound part: id -> the kept copy of the rewound text.
        var takenBack: [String: String] = [:]
    }
    private static let rewindColumns = "id, owner, conversation, after_row, at, rows, notes, topics, undo, undone"
    private func rewind(_ row: DeckMemoryRow) -> DeckMemoryRewind {
        func list(_ index: Int) -> [String] { (try? JSONDecoder().decode([String].self, from: Data(row.text(index).utf8))) ?? [] }
        return .init(id: row.int(0), owner: DeckMemoryOwner(key: row.text(1)) ?? .hoot, conversation: row.text(2), after: row.int(3),
                     at: row.date(4) ?? now(), rows: Int(row.int(5)), notes: list(6), topics: list(7), undoneAt: row.date(9))
    }
    private static func json<T: Encodable>(_ value: T) -> String { String(decoding: (try? JSONEncoder().encode(value)) ?? Data("[]".utf8), as: UTF8.self) }
    /// The moment a kept copy was made, from its name ("<topic>.20261011-143005.md" or "…-2.md"), in the app's own clock.
    private static func versionDate(_ name: String) -> Date? {
        guard let match = name.range(of: #"\.(\d{8})-(\d{6})(-\d+)?\.md$"#, options: .regularExpression) else { return nil }
        let digits = name[match].filter(\.isNumber).prefix(14)
        guard digits.count == 14 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(digits))
    }

    public func rewinds(owner: DeckMemoryOwner?, conversation: String?) async throws -> [DeckMemoryRewind] {
        var clauses: [String] = [], args: [DeckMemorySQL] = []
        if let owner { clauses.append("owner = ?"); args.append(.text(owner.key)) }
        if let conversation { clauses.append("conversation = ?"); args.append(.text(conversation)) }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return try db.rows("SELECT \(Self.rewindColumns) FROM rewinds\(filter) ORDER BY id DESC LIMIT 500", args).map(rewind)
    }

    public func markRewound(owner: DeckMemoryOwner, conversation: String, after: Int64) async throws -> DeckMemoryRewind {
        guard !conversation.isEmpty else { throw DeckMemoryError(.invalid, "A rewind needs the conversation it is in.") }
        let scope = "owner = ? AND conversation = ? AND id > ? AND rewound IS NULL"
        let scopeArgs: [DeckMemorySQL] = [.text(owner.key), .text(conversation), .int(after)]
        guard let span = try db.first("SELECT COUNT(*), MIN(saved), MIN(id), MAX(id) FROM diary WHERE \(scope)", scopeArgs), span.int(0) > 0 else {
            throw DeckMemoryError(.notFound, "There is nothing after that message to rewind.")
        }
        let at = now(), count = Int(span.int(0)), firstID = span.int(2), lastID = span.int(3)
        let began = Date(timeIntervalSince1970: (span.double(1) ?? at.timeIntervalSince1970).rounded(.down))
        let session = try db.first("SELECT session FROM diary WHERE \(scope) AND session IS NOT NULL LIMIT 1", scopeArgs)?.string(0)
        let id = try db.run("INSERT INTO rewinds (owner, conversation, after_row, at, rows) VALUES (?, ?, ?, ?, ?)",
                            [.text(owner.key), .text(conversation), .int(after), .date(at), .int(Int64(count))])
        try db.run("UPDATE diary SET rewound = ?, rewind_id = ? WHERE \(scope)", [.date(at), .int(id)] + scopeArgs)

        // Notes that rest ONLY on rewound rows are set aside. A note that also rests on an earlier row stays, and so
        // does a note with no record of the rows it came from (the store does not guess).
        var notes: [String] = []
        for row in try db.rows("SELECT id, diary_first, diary_last FROM notes WHERE owner = ? AND missing = 0 AND archived IS NULL AND diary_first IS NOT NULL AND diary_first >= ? AND diary_last <= ?",
                               [.text(owner.key), .int(firstID), .int(lastID)]) {
            // Every row of the note's range that belongs to this conversation must be one this rewind marked.
            let outside = try db.first("SELECT COUNT(*) FROM diary WHERE id >= ? AND id <= ? AND owner = ? AND (conversation IS NOT ? OR rewind_id IS NOT ?)",
                                       [.int(row.int(1)), .int(row.int(2)), .text(owner.key), .text(conversation), .int(id)])?.int(0) ?? 0
            let inside = try db.first("SELECT COUNT(*) FROM diary WHERE id >= ? AND id <= ? AND rewind_id = ?", [.int(row.int(1)), .int(row.int(2)), .int(id)])?.int(0) ?? 0
            guard inside > 0, outside == 0 else { continue }
            _ = try archiveNow(id: row.text(0), reason: "rewound", replacedBy: nil)
            notes.append(row.text(0))
        }

        // Topics written during the rewound part, by this conversation's session when the rows name one.
        var undo = RewindUndo()
        for row in try db.rows("SELECT id, path, session FROM topics WHERE owner = ? AND missing = 0 AND open = 1 AND date >= ?", [.text(owner.key), .date(began)]) {
            if let session, let theirs = row.string(2), theirs != session { continue }
            let topicID = row.text(0), path = row.text(1)
            guard let current = DeckMemoryFiles.read(url(path)) else { continue }
            // The first copy kept after the rewound part began holds the text the topic had before it.
            let stem = String(path.dropLast(3)), folder = url("archive/versions/" + (stem as NSString).deletingLastPathComponent)
            let prefix = (stem as NSString).lastPathComponent + "."
            let names: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }
            var earlier: (name: String, date: Date)?
            for name in names {
                guard let date = Self.versionDate(name), date >= began else { continue }
                if let best = earlier, best.date < date || (best.date == date && best.name <= name) { continue }
                earlier = (name, date)
            }
            if let earlier, let before = DeckMemoryFiles.read(folder.appendingPathComponent(earlier.name)) {
                guard before != current, let kept = keepVersion(of: path) else { continue }
                try DeckMemoryFiles.write(before, to: url(path))
                try indexTopic(path: path, owner: owner, id: topicID, text: before)
                undo.takenBack[topicID] = kept
            } else {
                // No earlier text: the topic began in the rewound part. It is set aside, not removed.
                var file = DeckMemoryFile(text: current)
                file.set("status", "rewound")
                try DeckMemoryFiles.write(file.text, to: url(path))
                try indexTopic(path: path, owner: owner, id: topicID, text: file.text)
                undo.setAside.append(topicID)
            }
        }
        let topics = undo.setAside + undo.takenBack.keys.sorted()
        try db.run("UPDATE rewinds SET notes = ?, topics = ?, undo = ? WHERE id = ?", [.text(Self.json(notes)), .text(Self.json(topics)), .text(Self.json(undo)), .int(id)])
        post(.diary, owner, String(after))
        if !notes.isEmpty { post(.notes, owner) }
        if !topics.isEmpty { post(.topics, owner) }
        return rewind(try db.first("SELECT \(Self.rewindColumns) FROM rewinds WHERE id = ?", [.int(id)])!)
    }

    public func undoRewind(id: Int64) async throws -> DeckMemoryRewind {
        guard let row = try db.first("SELECT \(Self.rewindColumns) FROM rewinds WHERE id = ?", [.int(id)]) else { throw missing("That rewind is not on record.") }
        let made = rewind(row)
        guard !made.isUndone else { return made }
        let owner = made.owner
        // Rewinds of one conversation come back in the order they were made, last first.
        if try db.first("SELECT 1 FROM rewinds WHERE owner = ? AND conversation = ? AND id > ? AND undone IS NULL", [.text(owner.key), .text(made.conversation), .int(id)]) != nil {
            throw DeckMemoryError(.conflict, "This conversation was rewound again after that. Undo the later rewind first.")
        }
        // Once the conversation has gone on, putting the old part back would mix two lines of talk.
        let newest = try db.first("SELECT COALESCE(MAX(id), 0) FROM diary WHERE rewind_id = ?", [.int(id)])?.int(0) ?? 0
        if try db.first("SELECT 1 FROM diary WHERE owner = ? AND conversation = ? AND id > ? AND rewound IS NULL AND role IN ('user', 'assistant')",
                        [.text(owner.key), .text(made.conversation), .int(newest)]) != nil {
            throw DeckMemoryError(.conflict, "The conversation has gone on since the rewind, so the rewound part cannot be put back into it. It is still in the diary.")
        }
        try db.run("UPDATE diary SET rewound = NULL, rewind_id = NULL WHERE rewind_id = ?", [.int(id)])
        for note in made.notes {
            guard let stored = try noteRow(note), !stored.isNull(12), stored.string(13) == "rewound" else { continue }
            _ = try await restoreNote(id: note)
        }
        let undo = (try? JSONDecoder().decode(RewindUndo.self, from: Data(row.text(8).utf8))) ?? RewindUndo()
        for topicID in undo.setAside {
            guard let stored = try db.first("SELECT path FROM topics WHERE owner = ? AND id = ? AND missing = 0", [.text(owner.key), .text(topicID)]),
                  let text = DeckMemoryFiles.read(url(stored.text(0))) else { continue }
            var file = DeckMemoryFile(text: text)
            guard file.value("status") == "rewound" else { continue }
            file.set("status", "open")
            try DeckMemoryFiles.write(file.text, to: url(stored.text(0)))
            try indexTopic(path: stored.text(0), owner: owner, id: topicID, text: file.text)
        }
        for (topicID, kept) in undo.takenBack {
            guard let stored = try db.first("SELECT path FROM topics WHERE owner = ? AND id = ? AND missing = 0", [.text(owner.key), .text(topicID)]),
                  let rewoundText = DeckMemoryFiles.read(url(kept)) else { continue }
            keepVersion(of: stored.text(0))
            try DeckMemoryFiles.write(rewoundText, to: url(stored.text(0)))
            try indexTopic(path: stored.text(0), owner: owner, id: topicID, text: rewoundText)
        }
        try db.run("UPDATE rewinds SET undone = ? WHERE id = ?", [.date(now()), .int(id)])
        post(.diary, owner, String(made.after))
        if !made.notes.isEmpty { post(.notes, owner) }
        if !made.topics.isEmpty { post(.topics, owner) }
        kickEmbedding()
        return rewind(try db.first("SELECT \(Self.rewindColumns) FROM rewinds WHERE id = ?", [.int(id)])!)
    }
}
