import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// A Markdown file with a flat label block on top ("front matter"). Unknown lines in the block are kept
/// exactly as they were, so a note imported from Claude Code keeps its own name/description/type.
struct DeckMemoryFile {
    private(set) var frontLines: [String]
    var body: String
    private(set) var hadFront: Bool

    init(text: String) {
        let lines = text.components(separatedBy: "\n")
        if text.hasPrefix("---"), lines[0].trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            frontLines = Array(lines[1..<end]); hadFront = true
            body = lines[(end + 1)...].joined(separator: "\n")
        } else {
            frontLines = []; hadFront = false; body = text
        }
    }
    init(body: String) { frontLines = []; hadFront = false; self.body = body }

    private static func key(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }
    func value(_ key: String) -> String? {
        for line in frontLines where Self.key(of: line) == key {
            var value = line[line.index(after: line.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last, (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
    /// nil or "" removes the key. Values are kept on one line.
    mutating func set(_ key: String, _ value: String?) {
        let clean = value?.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let index = frontLines.firstIndex { Self.key(of: $0) == key }
        guard let clean, !clean.isEmpty else { if let index { frontLines.remove(at: index) }; return }
        let line = key + ": " + clean
        if let index { frontLines[index] = line } else { frontLines.append(line) }
    }
    var keys: [String] { frontLines.compactMap(Self.key(of:)) }
    var text: String {
        frontLines.isEmpty ? body : "---\n" + frontLines.joined(separator: "\n") + "\n---\n" + body
    }

    /// The first "# Heading" when it is the first thing in the body, and the body without it.
    var headingAndRest: (title: String?, rest: String) {
        let lines = body.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return (nil, "") }
        let line = lines[first].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("# ") else { return (nil, body.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let rest = lines[(first + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), rest)
    }
}

enum DeckMemoryFiles {
    static let maxFileBytes = 1024 * 1024
    static func stamp(_ date: Date) -> String { ISO8601DateFormatter.string(from: date, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withInternetDateTime]) }
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if text.count == 10, let date = try? Date(text + "T12:00:00Z", strategy: .iso8601) { return date }
        return nil
    }
    static func day(_ date: Date, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func compact(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func shortID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<6).map { _ in letters[Int.random(in: 0..<letters.count)] })
    }

    static func read(_ file: URL) -> String? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= maxFileBytes, let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
    static func info(_ file: URL) -> (mtime: Double, bytes: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (attributes[.size] as? NSNumber)?.intValue ?? 0)
    }
    static func write(_ text: String, to file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch { throw DeckMemoryError(.io, "\(file.lastPathComponent) could not be saved: \(error.localizedDescription)") }
    }
    /// A path inside the root, or nil when it would leave it.
    static func relative(_ file: URL, root: URL) -> String? {
        let base = root.standardizedFileURL.path, path = file.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
    /// Markdown files under a folder (relative paths), skipping hidden names and the given top-level prefixes.
    static func markdown(under folder: URL, depth: Int = 8, limit: Int = 20_000, skip: (String) -> Bool = { _ in false }) -> [String] {
        var found: [String] = []
        func walk(_ directory: URL, _ prefix: String, _ level: Int) {
            guard level <= depth, found.count < limit,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                if skip(relative) { continue }
                let url = directory.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true { walk(url, relative, level + 1) }
                else if values.isRegularFile == true, name.lowercased().hasSuffix(".md") { found.append(relative); if found.count >= limit { return } }
            }
        }
        walk(folder, "", 1)
        return found
    }

    // MARK: What a path inside the memory folder is

    enum Kind: Equatable {
        case card, playbook
        case topic(id: String)
        case note(archived: Bool)
        case document(name: String)
        /// `<seat>/topics/<topic>/handoffs/<file>.md`, or `<seat>/handoffs/<file>.md` for the whole conversation.
        case handoff(topic: String?, archived: Bool)
    }
    /// The owner whose folder a path is in, and what kind of file it is. nil for files the index does not keep.
    static func classify(_ relative: String) -> (owner: DeckMemoryOwner, kind: Kind)? {
        var parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last, last.lowercased().hasSuffix(".md"), !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        var archived = false
        if parts.first == "archive" {
            guard parts.count > 2, parts[1] != "versions", parts[1] != "backups" else { return nil }
            archived = true; parts.removeFirst()
        }
        func plain(_ text: String) -> Bool { DeckMemoryOwner.folderName(text) == text }
        let owner: DeckMemoryOwner, rest: [String]
        switch parts.first {
        case "hoot": owner = .hoot; rest = Array(parts.dropFirst())
        case "roles":
            guard parts.count >= 3, plain(parts[1]) else { return nil }
            owner = .role(project: nil, role: parts[1]); rest = Array(parts.dropFirst(2))
        case "projects":
            guard parts.count >= 3, plain(parts[1]) else { return nil }
            if parts[2] == "lead" { owner = .lead(parts[1]); rest = Array(parts.dropFirst(3)) }
            else if parts[2] == "roles" {
                guard parts.count >= 5, plain(parts[3]) else { return nil }
                owner = .role(project: parts[1], role: parts[3]); rest = Array(parts.dropFirst(4))
            }
            else { owner = .project(parts[1]); rest = Array(parts.dropFirst(2)) }
        default: return nil
        }
        guard !rest.isEmpty else { return nil }
        let stem = String(last.dropLast(3))
        if rest.first == "notes", rest.count >= 2 { return (owner, .note(archived: archived)) }
        if rest.count == 4, rest[0] == "topics", rest[2] == "handoffs" { return (owner, .handoff(topic: rest[1], archived: archived)) }
        if rest.count == 2, rest[0] == "handoffs" { return (owner, .handoff(topic: nil, archived: archived)) }
        if archived { return nil }
        if rest == ["card.md"] { return (owner, .card) }
        if rest == ["playbook.md"] { return (owner, .playbook) }
        if rest.first == "topics", rest.count == 2 { return (owner, .topic(id: stem)) }
        if rest.count == 1 { return (owner, .document(name: stem)) }
        return nil
    }
    /// `templates/<category>/<card|checklist|settings>.md`.
    static func templateCategory(_ relative: String) -> DeckMemoryCategory? {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "templates", ["card.md", "checklist.md", "settings.md"].contains(parts[2]) else { return nil }
        return DeckMemoryCategory(rawValue: parts[1])
    }

    // MARK: The playbook table

    static let playbookHeader = ["Job", "AI", "Model", "Effort", "Permission", "Standing instructions"]
    static let playbookIntro = "# Playbook\n\nFor each kind of job: which AI, model, effort and permission to start the session with, and what it is always told. Edit the table; the app reads it as it is. The row called \"default\" is used when no other row fits.\n"
    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], current = "", escaped = false
        for character in text {
            if escaped { current.append(character == "|" ? "|" : "\\" + String(character)); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(current); current = "" }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br>", with: "\n") }
    }
    private static func cell(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }
    /// The text before the table, the rows, and the text after it.
    static func parsePlaybook(_ text: String) -> (preface: String, rows: [DeckMemoryPlaybookRow], trailer: String) {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }) else { return (text, [], "") }
        var end = start
        while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
        let table = Array(lines[start..<end]), header = cells(table[0]).map { $0.lowercased() }
        func column(_ names: [String]) -> Int? { header.firstIndex { name in names.contains { name == $0 || name.hasPrefix($0) } } }
        let job = column(["job"]) ?? 0, ai = column(["ai"]), model = column(["model"]), effort = column(["effort"])
        let permission = column(["permission"]), instructions = column(["standing", "instructions"])
        var rows: [DeckMemoryPlaybookRow] = []
        for line in table.dropFirst() {
            let values = cells(line)
            if values.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }) { continue }
            func at(_ index: Int?) -> String { index.flatMap { $0 < values.count ? values[$0] : nil } ?? "" }
            let kind = at(job)
            guard !kind.isEmpty else { continue }
            rows.append(.init(jobKind: kind, ai: at(ai), model: at(model), effort: at(effort), permission: at(permission), instructions: at(instructions)))
        }
        return (lines[..<start].joined(separator: "\n"), rows, lines[end...].joined(separator: "\n"))
    }
    static func playbookText(preface: String, rows: [DeckMemoryPlaybookRow], trailer: String) -> String {
        var out = preface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? playbookIntro : preface
        if !out.hasSuffix("\n") { out += "\n" }
        if !out.hasSuffix("\n\n") { out += "\n" }
        out += "| " + playbookHeader.joined(separator: " | ") + " |\n|" + playbookHeader.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in rows {
            out += "| " + [row.jobKind, row.ai, row.model, row.effort, row.permission, row.instructions].map(cell).joined(separator: " | ") + " |\n"
        }
        let rest = trailer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out += "\n" + rest + "\n" }
        return out
    }

    // MARK: START-HERE and the pointers

    static let generatedMarker = "<!-- terminal-deck:generated "
    static let startHereVersion = 1
    static func startHere() -> String {
        """
        # Start here

        This folder is the long-term memory that Terminal Deck keeps. It is plain text plus one database, so any AI app can pick it up, with or without Terminal Deck running. Read this file first.

        ## The idea

        There are exactly three kinds of worker: the **orchestrator** (Hoot, who talks with the person), a **lead** (one per big project), and an **agent** (everyone else). Each kind has one template that applies to every member, now and in future.

        Memory belongs to the **seat** (the role), never to whoever is sitting in it. "The iOS job on iMatch" is a seat. If the agent in it is deleted and a new one is hired, the new one finds all of the seat's memory here. Several sessions can fill one seat at the same time ("hands"); they all read and write the same seat.

        ## What is where

        ```
        templates/orchestrator|lead|agent/     card.md (shared rules), checklist.md, settings.md: one set per kind of worker
        hoot/                                  the orchestrator's seat: card.md, playbook.md, topics/, notes/
        projects/<project>/                    the project's shared card.md and notes/
        projects/<project>/lead/               the lead's seat: card.md, playbook.md, topics/, notes/
        projects/<project>/roles/<role>/       an agent seat in that project: card.md, topics/, notes/
        roles/<role>/                          an agent seat outside any project
        archive/                               everything that was replaced or put away; nothing is ever deleted
        memory.db                              the diary (every message, word for word), the board, and the search index
        ```

        A seat's `card.md` holds only that seat's own additions. What a worker is given is the template's `card.md` for its kind, followed by the seat's own `card.md`.

        ## How to pick up

        1. Read the template card for your kind (`templates/<kind>/card.md`), then your seat's own `card.md`. Inside a project, also read `projects/<project>/card.md`.
        2. Read the open topics in your seat's `topics/`. Each one says where one job stands. If you were given a job, its topic is the one with that job in its label block.
        3. Look at the board, which the app fills from what really happened:
           `sqlite3 memory.db "SELECT title, hand, job, doing, last_result, state, waiting FROM board WHERE archived IS NULL ORDER BY updated DESC LIMIT 40"`
        4. Search before you assume. Notes, topics and cards are files, so searching the folder works. The diary is in the database:
           `sqlite3 memory.db "SELECT kind, ref, title, snippet(search, 8, '[', ']', ' … ', 16) FROM search WHERE search MATCH 'your words' LIMIT 20"`
           `sqlite3 memory.db "SELECT datetime(at, 'unixepoch', 'localtime'), role, substr(text, 1, 400) FROM diary WHERE session = '<session id>' ORDER BY id DESC LIMIT 40"`

        ## The rules

        - Memory lives here, not in a chat. Trust these files over your own recollection.
        - Exact facts (which build is installed, did it ship) are checked at the source, never from memory.
        - Nothing is deleted. To retire a note, move it into `archive/` at the same path. A newer note replaces an older one by saying so: put `supersedes: <the old note's id>` in the label block at its top and link to the old note with `[[its file name]]`.
        - To add a note, create a NEW Markdown file in your seat's `notes/` folder: a `# Title` line, then a few short lines. Never write into another note's file; other hands may be writing at the same moment. The app adds the label block (seat, project, when) the next time it runs; do not invent one.
        - Keep cards short (one or two pages). The app warns when a card is too long; it never cuts it.
        - A result on the board is `attempted`, `reported` or `verified`. Only call something verified when you can point at the proof.
        - How you report back: done or not · the result in three lines · the proof · what you need.
        - Do not edit `memory.db` by hand. Read it freely.

        ## With Terminal Deck running

        Use the app's tools instead of the files: `memory.search`, `memory.card.read`, `memory.board.read`, `memory.note.add`, `memory.note.archive`, `memory.topic.update`, `playbook.read`, `playbook.update`. The app stamps which seat wrote what and where it belongs.

        \(generatedMarker)\(startHereVersion) -->
        """ + "\n"
    }
    static func pointer(_ app: String) -> String {
        """
        # Memory folder

        \(app): read `START-HERE.md` in this folder before anything else. It explains what is kept here (templates, seats with their cards, notes and topics, the diary and the board) and the rules for reading and adding to it.

        \(generatedMarker)\(startHereVersion) -->
        """ + "\n"
    }
    static let pointers: [(file: String, app: String)] = [("CLAUDE.md", "Claude Code"), ("AGENTS.md", "Codex"), ("GEMINI.md", "Gemini")]
}
