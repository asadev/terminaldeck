import Foundation
import TerminalDeckNativeCore

/// What a moment needs on top of the fixed top rules.
public enum DeckMemoryMoment: Sendable, Equatable {
    case plain
    /// Hoot or a lead is about to start or steer a session: the matching playbook row is added.
    case startingSession(job: String?)
    /// A permission question is on the table: the card's permission lines are added.
    case permissionQuestion
}

public struct DeckMemoryBriefText: Sendable, Equatable {
    public var text: String
    /// How many characters the card is over its cap (0 = fits). The card is still given whole.
    public var cardOverBy: Int
    /// False when the text is still longer than the limit it was asked to fit (only whole items are ever left out; nothing is cut mid-way).
    public var fits: Bool
    /// What was left out to fit, in plain words ("12 board rows", "2 topics", "the project's card"). Empty when everything is there.
    public var leftOut: [String]
    public init(text: String, cardOverBy: Int = 0, fits: Bool = true, leftOut: [String] = []) {
        self.text = text; self.cardOverBy = cardOverBy; self.fits = fits; self.leftOut = leftOut
    }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The same words for Hoot's desk and for terminal sessions, built only from the store's public calls.
public enum DeckMemoryBrief {
    public static let boardRowsInOpening = 24
    public static let boardChangesPerMessage = 8

    /// How much text each AI app passes on from a hook. Over it, the app silently hands the model a short
    /// preview instead, so the opening is fitted by measuring. nil = no such cap (Hoot's own desk).
    public enum Limit {
        /// Claude Code: at most 10,000 characters of hook output reach the model.
        public static let claudeCodeHook = 10_000
        /// Codex: about 2,500 tokens of hook output by default.
        public static let codexHook = 8_000
        /// The few lines that go with every message.
        public static let messageLines = 1_200
    }

    /// Text the app lays down is wrapped in this tag, so a capture reading a CLI's own record can take it out
    /// again and memory never stores its own words as something a person said.
    public static let tag = "deck-memory"
    public static func wrap(_ text: String) -> String { "<\(tag)>\n" + text + "\n</\(tag)>" }
    /// The text without anything the app put there.
    public static func stripInjected(_ text: String) -> String {
        guard text.contains("<" + tag + ">"), let regex = try? NSRegularExpression(pattern: "<\(tag)>[\\s\\S]*?</\(tag)>\\n?") else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The top of a clean desk: the full card (the category template + the seat's own additions), the open topics, and the board.
    /// `job`: the piece of work this hand holds. With it, only that job's topic and the seat-wide topics are laid down
    /// (another hand's topic is that hand's; the board shows who holds what).
    /// `limit`: fit the text to this many characters by leaving out WHOLE items, least loss first: the oldest board rows,
    /// then the oldest topics, then the project's card, then the seat's own card additions. Never the top rules, never
    /// a cut in the middle. The last line says what was left out and how to get it.
    public static func opening(_ memory: any DeckMemoryStoring, owner: DeckMemoryOwner, session: String? = nil, job: String? = nil,
                               limit: Int? = nil) async throws -> DeckMemoryBriefText {
        let card = try await memory.assembledCard(owner)
        let template = owner.category == nil ? nil : try? await memory.template(owner.category!)
        var projectCard = ""
        if owner.isSeat, let project = owner.projectID, let found = try? await memory.card(.project(project)) { projectCard = found.text }
        let topics = (template?.has(.topics) ?? true) ? try await memory.topics(owner, job: job, includeClosed: false) : []
        let rows = (template?.has(.board) ?? true) ? try await memory.board(.init(owner: owner, limit: boardRowsInOpening)) : []
        return opening(card: card, template: template, projectCard: projectCard, topics: topics, rows: rows,
                       root: await memory.location().root, owner: owner, limit: limit)
    }

    /// Both the store and startup's files-only source use this whole-item fitting rule.
    static func opening(card: DeckMemoryAssembledCard, template: DeckMemoryTemplate?, projectCard: String,
                        topics: [DeckMemoryTopic], rows: [DeckMemoryBoardRow], root: URL, owner: DeckMemoryOwner,
                        limit: Int?) -> DeckMemoryBriefText {
        func has(_ part: DeckMemoryPart) -> Bool { template?.has(part) ?? true }
        let head = "# Your memory (kept by Terminal Deck, not by this chat)\nThe app keeps your card, your open topics, your notes and a diary of every message in plain files and a database, and hands them to you at the top of every clean desk. This memory belongs to your seat, not to you alone: whoever held this seat before you built it, and it stays for whoever comes next. Trust it over your own recollection. Exact facts (which build is installed, did it ship) are checked at the source, never from memory."
        let shared = card.shared.trimmingCharacters(in: .whitespacesAndNewlines)
        var own = card.own.trimmingCharacters(in: .whitespacesAndNewlines)
        var projectCard = projectCard.trimmingCharacters(in: .whitespacesAndNewlines)
        var topics = topics, rows = rows
        let tail = "Your notes are files under \(root.path)/\(owner.notesFolder). Search them and the diary with the memory.search tool; memory.diary.read opens the moment around a hit."
        let topicCount = topics.count, rowCount = rows.count
        var droppedProject = false, droppedOwn = false
        func leftOut() -> [String] {
            var out: [String] = []
            if rowCount > rows.count { out.append("\(rowCount - rows.count) board row\(rowCount - rows.count == 1 ? "" : "s")") }
            if topicCount > topics.count { out.append("\(topicCount - topics.count) topic\(topicCount - topics.count == 1 ? "" : "s")") }
            if droppedProject { out.append("the project's card") }
            if droppedOwn { out.append("this seat's own card additions") }
            return out
        }
        func render() -> String {
            var parts = [head]
            // FINAL-CONNECT (SETTINGS-TRUTH row 95): the template's Card and Playbook switches are obeyed.
            let cardText = has(.card) ? [shared, own].filter { !$0.isEmpty }.joined(separator: "\n\n") : ""
            if !cardText.isEmpty {
                // The size meter is shown to the AI too, so it knows when the card needs trimming.
                parts.append("## Your card (\(card.characters) of \(card.limit) characters" + (card.overBy > 0 ? ", over by \(card.overBy)" : "") + ")\n" + cardText)
            }
            if !projectCard.isEmpty { parts.append("## The project's card\n" + projectCard) }
            if !topics.isEmpty {
                parts.append("## Where we are (open topics)\n" + topics.map { "### " + $0.title + "\n" + $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n"))
            }
            if !rows.isEmpty { parts.append("## The board (kept by the app from what really happened)\n" + rows.map(boardLine).joined(separator: "\n")) }
            parts.append(tail)
            let missing = leftOut()
            if !missing.isEmpty {
                parts.append("Not shown here to keep this short: " + missing.joined(separator: ", ") + ". Read them with memory.board.read, memory.card.read and memory.search before relying on what is above.")
            }
            return parts.joined(separator: "\n\n")
        }
        var text = render()
        if let limit {
            while text.count > limit, !rows.isEmpty { rows.removeLast(); text = render() }
            while text.count > limit, !topics.isEmpty { topics.removeLast(); text = render() }
            if text.count > limit, !projectCard.isEmpty { projectCard = ""; droppedProject = true; text = render() }
            if text.count > limit, !own.isEmpty {
                // The seat's top rules are never left out, even when the rest of its own card is.
                let rules = DeckMemoryCard.topRules(in: own)
                own = rules.isEmpty ? "" : "## Top rules (this seat)\n" + rules.map { $0.hasPrefix("-") || $0.hasPrefix("*") ? $0 : "- " + $0 }.joined(separator: "\n")
                droppedOwn = true; text = render()
            }
        }
        return .init(text: text, cardOverBy: card.overBy, fits: limit.map { text.count <= $0 } ?? true, leftOut: leftOut())
    }

    /// The few lines every message carries: the fixed top rules, lines that fit the moment, and what changed on the board.
    /// `limit`: fit by showing fewer board changes, then leaving out the moment's lines. Never the top rules.
    public static func messageLines(_ memory: any DeckMemoryStoring, owner: DeckMemoryOwner, since: Date?, moment: DeckMemoryMoment = .plain,
                                    limit: Int? = nil) async throws -> DeckMemoryBriefText {
        let card = try await memory.assembledCard(owner)
        let rules = card.topRules.isEmpty ? "" : "Top rules:\n" + card.topRules.map { $0.hasPrefix("-") || $0.hasPrefix("*") ? $0 : "- " + $0 }.joined(separator: "\n")
        var momentText = ""
        switch moment {
        case .plain: break
        case .startingSession(let job):
            // FINAL-CONNECT (row 95): the template's Playbook switch is obeyed.
            let template = owner.category == nil ? nil : try? await memory.template(owner.category!)
            if owner.hasPlaybook, template?.has(.playbook) ?? true, let row = try await memory.playbookRow(owner, job: job ?? "") {
                momentText = "Playbook for this job (" + row.jobKind + "): " + playbookLine(row)
            }
        case .permissionQuestion:
            let lines = section(named: ["permissions", "permission rules", "permission"], in: card.text)
            if !lines.isEmpty { momentText = "Permission rules:\n" + lines.joined(separator: "\n") }
        }
        var changed: [DeckMemoryBoardChange] = []
        if let since {
            // The last change per row is what matters now.
            var latest: [String: DeckMemoryBoardChange] = [:], order: [String] = []
            for change in try await memory.boardChanges(since: since, owner: owner) {
                if latest[change.row.id] == nil { order.append(change.row.id) }
                latest[change.row.id] = change
            }
            changed = order.compactMap { latest[$0] }
        }
        let total = changed.count
        var shown = Array(changed.suffix(boardChangesPerMessage)), droppedMoment = false
        func render() -> String {
            var lines: [String] = []
            if !rules.isEmpty { lines.append(rules) }
            if !momentText.isEmpty, !droppedMoment { lines.append(momentText) }
            if !shown.isEmpty {
                var text = "Changed on the board since your last message:\n" + shown.map { boardLine($0.row) }.joined(separator: "\n")
                if total > shown.count { text += "\n(and \(total - shown.count) more: read the board with memory.board.read)" }
                lines.append(text)
            } else if total > 0 {
                lines.append("\(total) board row\(total == 1 ? "" : "s") changed since your last message: read the board with memory.board.read.")
            }
            return lines.joined(separator: "\n\n")
        }
        var text = render()
        if let limit {
            while text.count > limit, !shown.isEmpty { shown.removeFirst(); text = render() }
            if text.count > limit, !momentText.isEmpty { droppedMoment = true; text = render() }
        }
        var leftOut: [String] = []
        if total > shown.count { leftOut.append("\(total - shown.count) board change\(total - shown.count == 1 ? "" : "s")") }
        if droppedMoment { leftOut.append("the lines for this moment") }
        return .init(text: text, cardOverBy: card.overBy, fits: limit.map { text.count <= $0 } ?? true, leftOut: leftOut)
    }

    /// One board row as one or two plain lines.
    public static func boardLine(_ row: DeckMemoryBoardRow) -> String {
        var line = "- " + (row.title.isEmpty ? row.id : row.title) + " (" + row.kind.rawValue + (row.labels.hand.map { ", hand \($0)" } ?? "") + ")"
        if let job = row.labels.job, !job.isEmpty, job != row.title { line += " [job: " + job + "]" }
        if !row.doing.isEmpty { line += ": " + row.doing }
        if !row.lastResult.isEmpty {
            line += "\n  Last result" + (row.state.map { " [" + $0.rawValue + "]" } ?? "") + ": " + row.lastResult.replacingOccurrences(of: "\n", with: "\n  ")
        }
        if !row.waitingForUser.isEmpty { line += "\n  Waiting for the person: " + row.waitingForUser }
        return line
    }

    public static func playbookLine(_ row: DeckMemoryPlaybookRow) -> String {
        var parts: [String] = []
        if !row.ai.isEmpty { parts.append("AI " + row.ai) }
        if !row.model.isEmpty { parts.append("model " + row.model) }
        if !row.effort.isEmpty { parts.append("effort " + row.effort) }
        if !row.permission.isEmpty { parts.append("permission " + row.permission) }
        var line = parts.joined(separator: ", ")
        if !row.instructions.isEmpty { line += (line.isEmpty ? "" : ". ") + row.instructions }
        return line
    }

    /// The non-empty lines under a heading with one of these names.
    static func section(named names: [String], in text: String) -> [String] {
        var inside = false, lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inside = names.contains(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()); continue
            }
            if inside, !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
