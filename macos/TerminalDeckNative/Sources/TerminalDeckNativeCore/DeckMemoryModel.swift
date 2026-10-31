import Foundation

// Deck Memory (design-2026-10-10/MEMORY-SPEC.md incl. section 3a, MEMORY-API.md): the value types
// every lane shares. Pure data, no I/O. The store itself is `DeckMemoryStoring` in the backend.

/// Exactly three. Each has ONE template (`templates/<category>/`) that applies to every member and every future hire.
public enum DeckMemoryCategory: String, Sendable, Codable, CaseIterable, Hashable {
    /// Hoot.
    case orchestrator
    /// The lead of a project.
    case lead
    /// Every worker, permanent or temporary, on any AI or model.
    case agent
    public var title: String { self == .orchestrator ? "Orchestrator" : self == .lead ? "Lead" : "Agent" }
    /// "the Orchestrator", "all Leads", "all Agents": for "Shared by … (template)".
    public var everyone: String { self == .orchestrator ? "the Orchestrator" : self == .lead ? "all Leads" : "all Agents" }
    public var templateFolder: String { "templates/" + rawValue }
}

/// Whose memory something is. Memory belongs to the SEAT (the role), never to the individual hire:
/// deleting an agent leaves the seat's memory, and the next hire in that seat inherits all of it.
/// Seats: `hoot/` (orchestrator), `projects/<project>/lead/`, `projects/<project>/roles/<role>/`, `roles/<role>/`.
/// `.project` is not a seat: it is the project's shared card and notes (`projects/<project>/`).
public enum DeckMemoryOwner: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The orchestrator seat.
    case hoot
    /// A project's shared card and notes, by its `PROJProject.id`.
    case project(String)
    /// The lead seat of a project (same project id).
    case lead(String)
    /// An agent seat: a role inside a project, or (project nil) a role outside any project.
    case role(project: String?, role: String)

    /// Same as `.role`. Reads better at a call site: `.seat(project: "imatch", role: "ios")`.
    public static func seat(project: String?, role: String) -> DeckMemoryOwner { .role(project: project, role: role) }
    /// Before spec 3a an agent had its own folder. It is now the seat named after it, outside any project.
    @available(*, deprecated, message: "Memory belongs to the seat: use .role(project:role:)")
    public static func agent(_ id: String) -> DeckMemoryOwner { .role(project: nil, role: id) }

    /// "hoot", "project:<id>", "lead:<id>", "role:<project>/<role>", "role:<role>": the spelling kept in files and the database.
    public var key: String {
        switch self {
        case .hoot: "hoot"
        case .project(let id): "project:" + DeckMemoryOwner.folderName(id)
        case .lead(let id): "lead:" + DeckMemoryOwner.folderName(id)
        case .role(let project, let role):
            "role:" + (project.map { DeckMemoryOwner.folderName($0) + "/" } ?? "") + DeckMemoryOwner.folderName(role)
        }
    }
    public init?(key: String) {
        if key == "hoot" { self = .hoot; return }
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let id = String(key[key.index(after: colon)...])
        func plain(_ text: String) -> Bool { !text.isEmpty && DeckMemoryOwner.folderName(text) == text }
        switch key[..<colon] {
        case "project": guard plain(id) else { return nil }; self = .project(id)
        case "lead": guard plain(id) else { return nil }; self = .lead(id)
        case "role":
            let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 1, plain(parts[0]) { self = .role(project: nil, role: parts[0]) }
            else if parts.count == 2, plain(parts[0]), plain(parts[1]) { self = .role(project: parts[0], role: parts[1]) }
            else { return nil }
        // Written before spec 3a.
        case "agent": guard plain(id) else { return nil }; self = .role(project: nil, role: id)
        default: return nil
        }
    }
    /// From a folder inside the memory root: "hoot", "projects/<id>", "projects/<id>/lead",
    /// "projects/<id>/roles/<role>", "roles/<role>".
    public init?(folder: String) {
        let parts = folder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        func plain(_ text: String) -> Bool { DeckMemoryOwner.folderName(text) == text }
        if parts == ["hoot"] { self = .hoot; return }
        guard parts.count >= 2, plain(parts[1]) else { return nil }
        if (parts[0] == "roles" || parts[0] == "agents"), parts.count == 2 { self = .role(project: nil, role: parts[1]) }
        else if parts[0] == "projects", parts.count == 2 { self = .project(parts[1]) }
        else if parts[0] == "projects", parts.count == 3, parts[2] == "lead" { self = .lead(parts[1]) }
        else if parts[0] == "projects", parts.count == 4, parts[2] == "roles", plain(parts[3]) { self = .role(project: parts[1], role: parts[3]) }
        else { return nil }
    }
    /// Either spelling: the key ("lead:crm") or the folder ("projects/crm/lead").
    public init?(_ text: String) {
        if let owner = DeckMemoryOwner(key: text) ?? DeckMemoryOwner(folder: text) { self = owner } else { return nil }
    }
    public var description: String { key }
    /// Which of the three categories this seat is in. nil for a project's shared space.
    public var category: DeckMemoryCategory? {
        switch self {
        case .hoot: .orchestrator
        case .lead: .lead
        case .role: .agent
        case .project: nil
        }
    }
    public var isSeat: Bool { category != nil }
    /// The project this owner sits in, if any.
    public var projectID: String? {
        switch self {
        case .project(let id), .lead(let id): DeckMemoryOwner.folderName(id)
        case .role(let project, _): project.map(DeckMemoryOwner.folderName)
        case .hoot: nil
        }
    }
    /// The role's name for an agent seat.
    public var roleID: String? { if case .role(_, let role) = self { return DeckMemoryOwner.folderName(role) }; return nil }
    /// Folder inside the memory root that holds this owner's card, notes and topics.
    public var folder: String {
        switch self {
        case .hoot: "hoot"
        case .project(let id): "projects/" + DeckMemoryOwner.folderName(id)
        case .lead(let id): "projects/" + DeckMemoryOwner.folderName(id) + "/lead"
        case .role(let project, let role):
            (project.map { "projects/" + DeckMemoryOwner.folderName($0) + "/" } ?? "") + "roles/" + DeckMemoryOwner.folderName(role)
        }
    }
    /// The seat's OWN additions. What a desk gets is the category template plus this (`assembledCard`).
    public var cardPath: String { folder + "/card.md" }
    public var notesFolder: String { folder + "/notes" }
    public var topicsFolder: String { folder + "/topics" }
    /// The orchestrator and leads keep a playbook.
    public var hasPlaybook: Bool {
        switch self {
        case .hoot, .lead: true
        default: false
        }
    }
    public var playbookPath: String { folder + "/playbook.md" }

    /// The folder name used for an id. An id that is already a plain, safe file name (a project id, a role
    /// slug) is kept exactly as it is, so every lane spells the folder the same way; anything else is slugged.
    public static func folderName(_ id: String) -> String {
        let plain = !id.isEmpty && id.utf8.count <= 120 && !id.hasPrefix(".") && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
            && !id.unicodeScalars.contains { $0 == "/" || $0 == ":" || $0 == "\\" || $0.value < 32 || $0.value == 127 }
        return plain ? id : slug(id)
    }
    /// Lowercase letters, digits and hyphens (the same shape as `PROJProject.id`).
    public static func slug(_ text: String) -> String {
        var out = "", lastHyphen = true
        for scalar in text.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                out.unicodeScalars.append(scalar); lastHyphen = false
            } else if !lastHyphen {
                out.append("-"); lastHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 80 { out = String(out.prefix(80)); while out.hasSuffix("-") { out.removeLast() } }
        return out.isEmpty ? "unnamed" : out
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let owner = DeckMemoryOwner(key: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a Deck Memory owner: \(text)"))
        }
        self = owner
    }
    public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(key) }
}

/// What the APP knows about where something came from. The caller (app code) fills this from
/// app state; an AI never chooses it. The store adds the date and the type.
public struct DeckMemoryStamp: Hashable, Sendable, Codable {
    /// The seat (or a project's shared space). Category and seat labels come from it.
    public var owner: DeckMemoryOwner
    public var project: String?
    public var session: String?
    /// The hire sitting in the seat right now (profile id or name), or the AI's name for a plain session.
    /// A history detail only: memory is never looked up by it.
    public var agent: String?
    /// Which hand on the seat this is (1, 2, 3…) when several sessions fill one seat at the same time. nil = the only hand.
    public var hand: Int?
    /// The job (the piece of work) this hand holds: a short stable name from the app, such as a task id or the job's title.
    /// "Where we are" topics are keyed to it, so three hands keep three topics.
    public var job: String?
    public init(owner: DeckMemoryOwner, project: String? = nil, session: String? = nil, agent: String? = nil, hand: Int? = nil, job: String? = nil) {
        self.owner = owner; self.project = project ?? owner.projectID; self.session = session; self.agent = agent
        self.hand = hand; self.job = job.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
    public static let hoot = DeckMemoryStamp(owner: .hoot, agent: "hoot")
    public var category: DeckMemoryCategory? { owner.category }
    public var seat: String { owner.key }
}

/// The labels every stored note, diary row, topic and board row carries. Stamped by the app:
/// category, project and seat (from `owner`), hand number and job, session, date, type, and the hire's name as a history detail.
public struct DeckMemoryLabels: Hashable, Sendable, Codable {
    public var owner: DeckMemoryOwner
    public var project: String?
    public var session: String?
    /// The hire at the time (history detail).
    public var agent: String?
    public var date: Date
    public var type: String
    /// Which hand on the seat wrote it (nil = the only hand).
    public var hand: Int?
    /// The job it belongs to.
    public var job: String?
    public init(owner: DeckMemoryOwner, project: String? = nil, session: String? = nil, agent: String? = nil, date: Date, type: String,
                hand: Int? = nil, job: String? = nil) {
        self.owner = owner; self.project = project; self.session = session; self.agent = agent; self.date = date; self.type = type
        self.hand = hand; self.job = job
    }
    public init(stamp: DeckMemoryStamp, date: Date, type: String) {
        self.init(owner: stamp.owner, project: stamp.project, session: stamp.session, agent: stamp.agent, date: date, type: type,
                  hand: stamp.hand, job: stamp.job)
    }
    public var stamp: DeckMemoryStamp { .init(owner: owner, project: project, session: session, agent: agent, hand: hand, job: job) }
    public var category: DeckMemoryCategory? { owner.category }
    public var seat: String { owner.key }
    public var hire: String? { agent }
}

// MARK: Templates (one per category) and the assembled card

/// The parts of memory a category can get.
public enum DeckMemoryPart: String, Sendable, Codable, CaseIterable, Hashable {
    /// "refresh" (the removed planned refresh, 28 Oct 2026) may still be named in an older settings.md: it is skipped.
    case card, notes, diary, topics, playbook, board, helper
    public var title: String {
        switch self {
        case .card: "Card"
        case .notes: "Notes"
        case .diary: "Diary"
        case .topics: "Topics"
        case .playbook: "Playbook"
        case .board: "Board"
        case .helper: "Helper notes"
        }
    }
}

/// The one template of a category. Editing it changes every member at once and every future hire.
/// On disk: `templates/<category>/card.md`, `checklist.md`, `settings.md`.
public struct DeckMemoryTemplate: Hashable, Sendable, Codable {
    public var category: DeckMemoryCategory
    /// The shared card text: rules, the report form, how to use memory.
    public var card: String
    /// What the helper looks for when it writes notes; the person's corrections are added here.
    public var checklist: String
    /// Which memory parts members of this category get.
    public var parts: Set<DeckMemoryPart>
    /// The helper's AI ("claude", "codex", "gemini") and model.
    public var helperAI: String
    public var helperModel: String
    /// The size cap of a seat's assembled card (template + own), in characters.
    public var cardLimit: Int
    /// How many hands (sessions at the same time) one seat of this category may have. Default 3 for agents.
    public var handsPerSeat: Int
    /// How many hands of this category one project may have in all.
    public var handsPerProject: Int
    public var updatedAt: Date?
    public init(category: DeckMemoryCategory, card: String, checklist: String, parts: Set<DeckMemoryPart>,
                helperAI: String = "claude", helperModel: String = "sonnet", cardLimit: Int = DeckMemoryCard.defaultLimit,
                handsPerSeat: Int? = nil, handsPerProject: Int? = nil, updatedAt: Date? = nil) {
        self.category = category; self.card = card; self.checklist = checklist; self.parts = parts
        self.helperAI = helperAI; self.helperModel = helperModel
        self.cardLimit = cardLimit; self.updatedAt = updatedAt
        self.handsPerSeat = handsPerSeat ?? DeckMemoryTemplate.defaultHandsPerSeat(category)
        self.handsPerProject = handsPerProject ?? DeckMemoryTemplate.defaultHandsPerProject(category)
    }
    /// One desk for the orchestrator and for a lead; three hands for an agent seat.
    public static func defaultHandsPerSeat(_ category: DeckMemoryCategory) -> Int { category == .agent ? 3 : 1 }
    public static func defaultHandsPerProject(_ category: DeckMemoryCategory) -> Int { category == .agent ? 12 : 1 }
    public var folder: String { category.templateFolder }
    public func has(_ part: DeckMemoryPart) -> Bool { parts.contains(part) }
}

/// What a seat is actually given: the category template plus the seat's own additions. Never cut.
public struct DeckMemoryAssembledCard: Hashable, Sendable, Codable {
    public var owner: DeckMemoryOwner
    public var category: DeckMemoryCategory?
    /// "Shared by all Agents (template)": the category template's card text ("" for a project's shared space).
    public var shared: String
    /// "This role's own": the seat's own additions.
    public var own: String
    /// What is delivered: `shared`, then `own`.
    public var text: String
    public var characters: Int
    public var limit: Int
    /// 0 when it fits; otherwise how many characters over. Show it; never cut silently.
    public var overBy: Int
    /// The lines under "## Top rules" in the template and in the seat's own card (sent with every message).
    public var topRules: [String]
    public init(owner: DeckMemoryOwner, shared: String, own: String, limit: Int) {
        self.owner = owner; category = owner.category; self.shared = shared; self.own = own; self.limit = limit
        let a = shared.trimmingCharacters(in: .whitespacesAndNewlines), b = own.trimmingCharacters(in: .whitespacesAndNewlines)
        text = a.isEmpty ? b : b.isEmpty ? a : a + "\n\n" + b
        characters = text.count; overBy = max(0, text.count - limit)
        var rules: [String] = []
        for rule in DeckMemoryCard.topRules(in: shared) + DeckMemoryCard.topRules(in: own) where !rules.contains(rule) { rules.append(rule) }
        topRules = rules
    }
    public var fits: Bool { overBy == 0 }
}

// MARK: Notes

/// An open set: imported notes keep whatever type their source gave them.
public struct DeckMemoryNoteType: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.isEmpty ? "note" : rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }
    public static let decision: DeckMemoryNoteType = "decision"
    public static let preference: DeckMemoryNoteType = "preference"
    public static let correction: DeckMemoryNoteType = "correction"
    public static let result: DeckMemoryNoteType = "result"
    public static let openItem: DeckMemoryNoteType = "open-item"
    public static let lesson: DeckMemoryNoteType = "lesson"
    /// How to run, test, build or release something, once it has worked.
    public static let howTo: DeckMemoryNoteType = "how-to"
    public static let note: DeckMemoryNoteType = "note"
    /// The kinds the helper writes; shown first in pickers.
    public static let standard: [DeckMemoryNoteType] = [.decision, .preference, .correction, .result, .openItem, .lesson, .howTo, .note]
    /// Plain words for a picker or a section title.
    public var title: String {
        switch rawValue {
        case "decision": "Decision"
        case "preference": "Preference"
        case "correction": "Correction"
        case "result": "Result"
        case "open-item": "Open item"
        case "lesson": "Lesson"
        case "how-to": "How-to"
        case "note": "Note"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst().replacingOccurrences(of: "-", with: " ")
        }
    }
}

public struct DeckMemoryNoteDraft: Sendable {
    public var title: String
    public var body: String
    public var type: DeckMemoryNoteType
    public var stamp: DeckMemoryStamp
    /// The id of the note this one replaces. The old note is archived and stays linked.
    public var supersedes: String?
    /// Who wrote it: "helper", "agent", "user", "tidy-up", "import", "migration".
    public var source: String
    /// When the note was written, when the app knows better than "now". nil = now.
    public var date: Date?
    /// When what it says became true: the stamp of the diary row it came from. nil = `date`.
    /// Replacing is judged by this, not by when a note was written.
    public var validFrom: Date?
    /// The diary rows it came from (first...last id), so the profile and a search can jump to the moment.
    public var diaryRange: ClosedRange<Int64>?
    /// Whose words the note records: `.person` when the person said or typed it (only those may become rules, and only
    /// those may replace a note that came from the person); the seat's own AI, a tool or the app otherwise.
    /// `source` says who WROTE the note (the helper, an agent); `author` says whose words it holds. nil = not recorded.
    public var author: DeckMemoryAuthor?
    /// The very short title (3 to 6 words) lists show. nil = the app makes one (first words now, the helper's later).
    public var shortTitle: String?
    public init(title: String, body: String, type: DeckMemoryNoteType = .note, stamp: DeckMemoryStamp,
                supersedes: String? = nil, source: String = "user", date: Date? = nil, validFrom: Date? = nil, diaryRange: ClosedRange<Int64>? = nil,
                author: DeckMemoryAuthor? = nil, shortTitle: String? = nil) {
        self.title = title; self.body = body; self.type = type; self.stamp = stamp; self.supersedes = supersedes; self.source = source
        self.date = date; self.validFrom = validFrom; self.diaryRange = diaryRange; self.author = author; self.shortTitle = shortTitle
    }
}

/// Asad (12 Oct): "very short titles always automatically created for every rule instead of explaining the whole rule,
/// but clickable". Every note and every top rule gets 3 to 6 words. The memory helper writes them; until it has (or when
/// it is off) the app uses the rule's own first words. Lists show the short title; a click shows the whole rule.
public enum DeckMemoryShortTitle {
    /// Who made a short title: the helper AI, the person, or the app from the first words.
    public enum Maker: String, Sendable, Codable { case helper, person, firstWords = "first-words" }
    public static let maximumWords = 6
    static let trailing: Set<String> = ["a", "an", "the", "to", "of", "and", "or", "for", "from", "with", "in", "on", "at", "by", "is", "are",
                                        "was", "be", "that", "this", "it", "its", "as", "but", "so", "if", "when", "not", "no"]
    /// A plain short title from the rule's own words: date openers and list marks taken off, at most six words,
    /// never ending on a little word ("the", "to", "from").
    public static func fallback(_ text: String) -> String {
        var line = (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text).trimmingCharacters(in: .whitespaces)
        for mark in ["- [ ]", "- [x]", "-", "*", "•", "+"] where line.hasPrefix(mark + " ") { line = String(line.dropFirst(mark.count + 1)); break }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // "On 2026-10-11 Hoot said …" → "Hoot said …"
        if let range = line.range(of: #"^(On|As of|Since|From)\s+\d{4}-\d{2}-\d{2}[,:]?\s+"#, options: [.regularExpression, .caseInsensitive]) {
            line = String(line[range.upperBound...])
        }
        // A rule written "Name: explanation" or "Name — explanation" already has its title.
        for separator in [": ", " — ", " – ", " - "] {
            if let range = line.range(of: separator) {
                let head = String(line[..<range.lowerBound])
                let count = head.split(separator: " ").count
                if count >= 1, count <= maximumWords, head.count >= 3 { line = head; break }
            }
        }
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if words.count > maximumWords { words = Array(words.prefix(maximumWords)) }
        while words.count > 1, let last = words.last, trailing.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) { words.removeLast() }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?—–-"))
        if let first = title.first, first.isLowercase { title = first.uppercased() + title.dropFirst() }
        return title.isEmpty ? String(text.prefix(40)) : title
    }
    /// Cleans what an AI wrote: one line, no quotes or end punctuation, at most six words. nil when nothing usable is left.
    public static func cleaned(_ raw: String?) -> String? {
        guard var text = raw?.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’`*#-.:;!"))
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        let kept = words.prefix(maximumWords + 2).joined(separator: " ")
        return kept.isEmpty ? nil : String(kept.prefix(60))
    }
    /// The key a top rule's title is kept under: the rule's words, lower-case, spacing squeezed.
    public static func ruleKey(_ rule: String) -> String {
        var line = rule.trimmingCharacters(in: .whitespaces)
        for mark in ["-", "*", "•", "+"] where line.hasPrefix(mark + " ") { line = String(line.dropFirst(mark.count + 1)); break }
        return line.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// The value key that holds every top rule's short title (one JSON object: rule key → title).
    public static let ruleTitlesKey = "rules.short-titles"
}

public struct DeckMemoryNote: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var title: String
    /// Markdown without the label block at the top of the file.
    public var body: String
    public var type: DeckMemoryNoteType
    public var labels: DeckMemoryLabels
    /// Where the file is, relative to the memory root (under `archive/` once archived).
    public var path: String
    /// The note this one replaced / was replaced by (ids).
    public var supersedes: String?
    public var supersededBy: String?
    public var archivedAt: Date?
    /// "superseded", "archived", or the reason given.
    public var archiveReason: String?
    public var source: String
    /// `[[link]]` and Markdown link targets found in the body.
    public var links: [String]
    public var updatedAt: Date
    /// When what it says became true (`labels.date` is when it was written).
    public var validFrom: Date
    /// When it stopped being true: the moment the note that replaced it became true.
    public var validUntil: Date?
    /// The diary rows it came from.
    public var diaryRange: ClosedRange<Int64>?
    /// Set only on the answer to `addNote` when the same text was already in this seat: the id of that note. Nothing was written.
    public var duplicateOf: String?
    /// Set only on the answer to `addNote` when the note it was meant to replace was left standing: why, in plain words.
    public var notReplaced: String?
    /// Whose words it records (nil = not recorded; treat that as "not the person").
    public var author: DeckMemoryAuthor?
    /// The 3-to-6-word title lists show (front matter `short`). nil on an older note until the app gives it one.
    public var shortTitle: String?
    /// Who made `shortTitle` (front matter `short_by`).
    public var shortTitleBy: DeckMemoryShortTitle.Maker?
    /// What a list shows: the short title, or the first words of the title until there is one.
    public var listTitle: String { shortTitle.flatMap { $0.isEmpty ? nil : $0 } ?? DeckMemoryShortTitle.fallback(title) }
    /// True only when the app recorded that these are the person's own words.
    public var isFromThePerson: Bool { author == .person }
    public var isArchived: Bool { archivedAt != nil }
    public var status: DeckMemoryNoteStatus {
        guard archivedAt != nil else { return .current }
        switch archiveReason {
        case "superseded": return .superseded
        case "merged": return .merged
        case "history": return .history
        case "rewound": return .rewound
        default: return .archived
        }
    }
    public init(id: String, title: String, body: String, type: DeckMemoryNoteType, labels: DeckMemoryLabels, path: String,
                supersedes: String? = nil, supersededBy: String? = nil, archivedAt: Date? = nil, archiveReason: String? = nil,
                source: String = "user", links: [String] = [], updatedAt: Date, validFrom: Date? = nil, validUntil: Date? = nil,
                diaryRange: ClosedRange<Int64>? = nil, author: DeckMemoryAuthor? = nil) {
        self.id = id; self.title = title; self.body = body; self.type = type; self.labels = labels; self.path = path
        self.supersedes = supersedes; self.supersededBy = supersededBy; self.archivedAt = archivedAt; self.archiveReason = archiveReason
        self.source = source; self.links = links; self.updatedAt = updatedAt
        self.validFrom = validFrom ?? labels.date; self.validUntil = validUntil; self.diaryRange = diaryRange; self.author = author
    }
}

/// Where a note stands. Only `current` notes are handed to a desk.
public enum DeckMemoryNoteStatus: String, Sendable, Codable, CaseIterable {
    case current
    /// A newer note explicitly replaced it.
    case superseded
    /// It said the same as a fuller note and was folded into that one.
    case merged
    /// It arrived late and describes an earlier state than the note that is current.
    case history
    /// Put away by hand.
    case archived
    /// It came only from a part of a conversation the person rewound. It comes back if the rewind is undone.
    case rewound
    public var title: String {
        switch self {
        case .current: "Current"
        case .superseded: "Replaced"
        case .merged: "Merged"
        case .history: "Earlier state"
        case .archived: "Archived"
        case .rewound: "Set aside by a rewind"
        }
    }
}

public struct DeckMemoryNoteQuery: Sendable {
    /// Exactly this seat's notes.
    public var owner: DeckMemoryOwner?
    /// Every note in this project, whichever seat wrote it.
    public var project: String?
    public var session: String?
    public var agent: String?
    public var type: DeckMemoryNoteType?
    public var since: Date?
    public var includeArchived: Bool
    public var archivedOnly: Bool
    public var limit: Int
    /// Only notes written for this job.
    public var job: String?
    public init(owner: DeckMemoryOwner? = nil, project: String? = nil, session: String? = nil, agent: String? = nil,
                type: DeckMemoryNoteType? = nil, since: Date? = nil, includeArchived: Bool = false, archivedOnly: Bool = false, limit: Int = 500,
                job: String? = nil) {
        self.owner = owner; self.project = project; self.session = session; self.agent = agent; self.type = type; self.since = since
        self.includeArchived = includeArchived; self.archivedOnly = archivedOnly; self.limit = limit; self.job = job
    }
}

// MARK: Diary

public enum DeckMemoryDiaryRole: String, Sendable, Codable, CaseIterable {
    /// What the person typed.
    case user
    /// What the AI answered.
    case assistant
    /// A line the app put on the desk (card, per-message lines).
    case system
    /// A tool call or its result, when the capture keeps them.
    case tool
    /// Something that happened (session started, turn ended, permission asked).
    case event
}

/// Who really wrote a message. In a terminal session the "user" side is often Hoot or a lead, not the person,
/// so the role alone never says. Filled by the app from the event, never from the text.
public enum DeckMemoryAuthor: String, Sendable, Codable, CaseIterable, Hashable {
    /// The person at the keyboard. Only this may create a preference, a correction or a rule.
    case person
    case orchestrator, lead, agent
    /// A tool's output (a command, a web page, a file).
    case tool
    /// Text the app itself put on the desk (card, per-message lines).
    case app
    /// What a seat's own AI is called as an author: Hoot `.orchestrator`, a lead `.lead`, a role seat `.agent`.
    /// nil for a project's shared space, which no AI sits in.
    public static func of(_ owner: DeckMemoryOwner) -> DeckMemoryAuthor? {
        switch owner.category {
        case .orchestrator: .orchestrator
        case .lead: .lead
        case .agent: .agent
        case nil: nil
        }
    }
}

public struct DeckMemoryDiaryDraft: Sendable {
    public var stamp: DeckMemoryStamp
    public var role: DeckMemoryDiaryRole
    /// Word for word. Never shortened by the store.
    public var text: String
    /// The chat this belongs to (Hoot's conversation id, a session id). The visible chat renders from it.
    public var conversation: String?
    public var turn: String?
    /// A key from the source (a transcript line id). The same key is stored once, so a capture can be replayed safely.
    public var externalID: String?
    /// When it was said, if the app knows better than "now" (a line read from a CLI's own record). nil = now.
    public var at: Date?
    public var meta: [String: String]
    /// Who really wrote it. nil = the app did not say; treat that as "not the person".
    public var author: DeckMemoryAuthor?
    public init(stamp: DeckMemoryStamp, role: DeckMemoryDiaryRole, text: String, conversation: String? = nil, turn: String? = nil,
                externalID: String? = nil, at: Date? = nil, meta: [String: String] = [:], author: DeckMemoryAuthor? = nil) {
        self.stamp = stamp; self.role = role; self.text = text; self.conversation = conversation; self.turn = turn
        self.externalID = externalID; self.at = at; self.meta = meta; self.author = author
    }
}

public struct DeckMemoryDiaryEntry: Identifiable, Hashable, Sendable, Codable {
    /// Grows with every row: use it as "read from here" (`DeckMemoryDiaryQuery.after`).
    public let id: Int64
    /// `labels.type` is the role; `labels.date` is when the app saved it.
    public var labels: DeckMemoryLabels
    public var role: DeckMemoryDiaryRole
    public var text: String
    public var conversation: String?
    public var turn: String?
    public var externalID: String?
    public var meta: [String: String]
    /// Who really wrote it (nil = the app did not say).
    public var author: DeckMemoryAuthor?
    /// When the person rewound the conversation to before this row. A rewound row is kept as history; it is no
    /// longer part of the live conversation, so the chat, the helper and a desk rebuild leave it out.
    public var rewoundAt: Date?
    public var at: Date { labels.date }
    /// True only when the app recorded that the person typed this.
    public var isFromThePerson: Bool { author == .person }
    public var isRewound: Bool { rewoundAt != nil }
    public init(id: Int64, labels: DeckMemoryLabels, role: DeckMemoryDiaryRole, text: String, conversation: String? = nil,
                turn: String? = nil, externalID: String? = nil, meta: [String: String] = [:], author: DeckMemoryAuthor? = nil,
                rewoundAt: Date? = nil) {
        self.id = id; self.labels = labels; self.role = role; self.text = text; self.conversation = conversation; self.turn = turn
        self.externalID = externalID; self.meta = meta; self.author = author; self.rewoundAt = rewoundAt
    }
}

public extension DeckMemoryDiaryEntry {
    /// `meta["source"]` of a row a builder's test sent from code (never typed by the person).
    static let builderTestSource = "dev-test"
    /// Who wrote the row, in plain words, from the AUTHOR field (the role only for older rows that have none).
    /// "You" only for the person's own words. `name`: the hire's display name when the caller knows it; otherwise the
    /// hire's id from the labels. The Diary list and search results use this one rule.
    func writerName(name: String? = nil) -> String {
        if meta["source"] == Self.builderTestSource { return "Builder test" }
        let hire = name ?? labels.agent.flatMap { $0.isEmpty ? nil : $0 }
        switch author {
        case .person: return "You"
        case .orchestrator: return "Hoot"
        case .lead: return hire ?? "Lead"
        case .agent: return hire ?? "Agent"
        case .tool: return "Tool"
        case .app: return "App"
        case nil:
            switch role {
            case .user: return "You"
            case .assistant: return hire ?? (labels.owner == .hoot ? "Hoot" : "AI")
            case .tool: return "Tool"
            case .system: return "App"
            case .event: return "Event"
            }
        }
    }
}

public struct DeckMemoryDiaryQuery: Sendable {
    public var owner: DeckMemoryOwner?
    public var project: String?
    public var session: String?
    public var agent: String?
    public var conversation: String?
    public var roles: Set<DeckMemoryDiaryRole>?
    /// Only rows with a larger id (the helper's "new part only").
    public var after: Int64?
    /// Only rows with a smaller id (paging back through a chat).
    public var before: Int64?
    public var since: Date?
    public var until: Date?
    public var limit: Int
    /// false: oldest first (reading order). true: newest first.
    public var newestFirst: Bool
    /// Only rows of this job.
    public var job: String?
    /// Only rows written by these (for example `[.person]`).
    public var authors: Set<DeckMemoryAuthor>?
    /// false (the default): only the live conversation. true: rewound rows too, each with `rewoundAt` set (a history view).
    public var includeRewound: Bool
    public init(owner: DeckMemoryOwner? = nil, project: String? = nil, session: String? = nil, agent: String? = nil,
                conversation: String? = nil, roles: Set<DeckMemoryDiaryRole>? = nil, after: Int64? = nil, before: Int64? = nil,
                since: Date? = nil, until: Date? = nil, limit: Int = 200, newestFirst: Bool = false, job: String? = nil,
                authors: Set<DeckMemoryAuthor>? = nil, includeRewound: Bool = false) {
        self.owner = owner; self.project = project; self.session = session; self.agent = agent; self.conversation = conversation
        self.roles = roles; self.after = after; self.before = before; self.since = since; self.until = until
        self.limit = limit; self.newestFirst = newestFirst; self.job = job; self.authors = authors; self.includeRewound = includeRewound
    }
}

/// One rewind of a conversation: the person went back to a chosen message, and what came after was set aside.
/// Nothing is deleted: the rows stay in the diary marked as rewound, and it can be undone.
public struct DeckMemoryRewind: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public var owner: DeckMemoryOwner
    public var conversation: String
    /// The last diary row that stays in the conversation.
    public var after: Int64
    public var at: Date
    /// How many diary rows were set aside.
    public var rows: Int
    /// Notes that came ONLY from those rows: archived with the reason "rewound" (restorable).
    public var notes: [String]
    /// Topics that were written only in the rewound part (set aside), or taken back to the text they had before it.
    public var topics: [String]
    public var undoneAt: Date?
    public var isUndone: Bool { undoneAt != nil }
    public init(id: Int64, owner: DeckMemoryOwner, conversation: String, after: Int64, at: Date, rows: Int, notes: [String] = [],
                topics: [String] = [], undoneAt: Date? = nil) {
        self.id = id; self.owner = owner; self.conversation = conversation; self.after = after; self.at = at; self.rows = rows
        self.notes = notes; self.topics = topics; self.undoneAt = undoneAt
    }
}

// MARK: Board

public enum DeckMemoryBoardKind: String, Sendable, Codable, CaseIterable { case project, session, agent, task, chat }

/// How far a result can be trusted. `verified` needs proof.
public enum DeckMemoryResultState: String, Sendable, Codable, CaseIterable, Comparable {
    case attempted, reported, verified
    private var rank: Int { self == .attempted ? 0 : self == .reported ? 1 : 2 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    public var title: String { self == .attempted ? "Attempted" : self == .reported ? "Reported" : "Verified" }
}

/// One change to a board row, sent by app code from an app event. A nil field is left as it is;
/// an empty string clears it.
public struct DeckMemoryBoardUpdate: Sendable {
    /// Stable per thing: use `DeckMemoryBoardRow.rowID(kind, id)`, e.g. "session:<session id>".
    public var id: String
    public var kind: DeckMemoryBoardKind
    public var stamp: DeckMemoryStamp
    public var title: String?
    /// What it is doing now.
    public var doing: String?
    /// The last result, 2 to 3 lines.
    public var lastResult: String?
    /// What waits for the person.
    public var waitingForUser: String?
    /// A new `lastResult` without a state counts as `attempted`.
    public var state: DeckMemoryResultState?
    /// Where the proof is (a check that ran, a build number, a file). Required for `verified`.
    public var proof: String?
    public init(id: String, kind: DeckMemoryBoardKind, stamp: DeckMemoryStamp, title: String? = nil, doing: String? = nil,
                lastResult: String? = nil, waitingForUser: String? = nil, state: DeckMemoryResultState? = nil, proof: String? = nil) {
        self.id = id; self.kind = kind; self.stamp = stamp; self.title = title; self.doing = doing; self.lastResult = lastResult
        self.waitingForUser = waitingForUser; self.state = state; self.proof = proof
    }
}

public struct DeckMemoryBoardRow: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var kind: DeckMemoryBoardKind
    public var title: String
    /// `labels.date` is the last change; `labels.type` is the kind.
    public var labels: DeckMemoryLabels
    public var doing: String
    public var lastResult: String
    public var waitingForUser: String
    public var state: DeckMemoryResultState?
    public var proof: String
    public var updatedAt: Date
    public var archivedAt: Date?
    public var isWaiting: Bool { !waitingForUser.isEmpty }
    public static func rowID(_ kind: DeckMemoryBoardKind, _ id: String) -> String { kind.rawValue + ":" + id }
    public init(id: String, kind: DeckMemoryBoardKind, title: String, labels: DeckMemoryLabels, doing: String = "", lastResult: String = "",
                waitingForUser: String = "", state: DeckMemoryResultState? = nil, proof: String = "", updatedAt: Date, archivedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.labels = labels; self.doing = doing; self.lastResult = lastResult
        self.waitingForUser = waitingForUser; self.state = state; self.proof = proof; self.updatedAt = updatedAt; self.archivedAt = archivedAt
    }
}

public struct DeckMemoryBoardQuery: Sendable {
    /// Rows this owner cares about: Hoot sees all; a project or its lead the project's; a role seat its own rows.
    public var owner: DeckMemoryOwner?
    public var project: String?
    public var session: String?
    public var agent: String?
    public var kinds: Set<DeckMemoryBoardKind>?
    public var waitingOnly: Bool
    public var changedSince: Date?
    public var includeArchived: Bool
    public var limit: Int
    /// Exactly this seat's rows (every hand on it), whoever is asking. `owner` is "what this owner may see".
    public var seat: DeckMemoryOwner?
    public var job: String?
    public init(owner: DeckMemoryOwner? = nil, project: String? = nil, session: String? = nil, agent: String? = nil,
                kinds: Set<DeckMemoryBoardKind>? = nil, waitingOnly: Bool = false, changedSince: Date? = nil,
                includeArchived: Bool = false, limit: Int = 500, seat: DeckMemoryOwner? = nil, job: String? = nil) {
        self.owner = owner; self.project = project; self.session = session; self.agent = agent; self.kinds = kinds
        self.waitingOnly = waitingOnly; self.changedSince = changedSince; self.includeArchived = includeArchived; self.limit = limit
        self.seat = seat; self.job = job
    }
}

/// One recorded change of a board row (the board's own history; never rewritten).
public struct DeckMemoryBoardChange: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public var row: DeckMemoryBoardRow
    /// Which fields changed: "title", "doing", "lastResult", "waitingForUser", "state", "proof", "archived".
    public var fields: [String]
    public var at: Date
    public init(id: Int64, row: DeckMemoryBoardRow, fields: [String], at: Date) { self.id = id; self.row = row; self.fields = fields; self.at = at }
}

// MARK: Topics ("where we are")

public struct DeckMemoryTopic: Identifiable, Hashable, Sendable, Codable {
    /// The file name without ".md": a slug of the job when it was written for a job, else of the title. Unique per seat.
    public let id: String
    public var owner: DeckMemoryOwner
    public var title: String
    public var body: String
    public var open: Bool
    public var path: String
    public var labels: DeckMemoryLabels
    public var updatedAt: Date
    /// The job this topic follows (nil = a topic of the whole seat). A topic written with a job is keyed to that job.
    public var job: String? { labels.job }
    /// A topic is handed to every clean desk, so it has a size cap too. Over it is reported, never cut.
    public static let defaultLimit = 3000
    public var characters: Int { body.count }
    public var limit: Int { DeckMemoryTopic.defaultLimit }
    public var overBy: Int { max(0, body.count - DeckMemoryTopic.defaultLimit) }
    public init(id: String, owner: DeckMemoryOwner, title: String, body: String, open: Bool, path: String, labels: DeckMemoryLabels, updatedAt: Date) {
        self.id = id; self.owner = owner; self.title = title; self.body = body; self.open = open; self.path = path
        self.labels = labels; self.updatedAt = updatedAt
    }
}

// MARK: Handoffs

/// A handoff: one Markdown document, kept with a topic (or with the whole conversation), written so another AI
/// or person can pick the work up cold. The seat's own AI writes it. Never deleted: archived like a note.
public struct DeckMemoryHandoff: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var owner: DeckMemoryOwner
    /// The topic it is kept with (a topic id). nil = it covers the whole conversation.
    public var topic: String?
    public var title: String
    /// The document, without the label block at the top of its file.
    public var markdown: String
    /// `labels.date` is when it was written.
    public var labels: DeckMemoryLabels
    /// The file, relative to the memory root (under `archive/` once archived).
    public var path: String
    /// Who wrote it: the seat's own AI (`.orchestrator`, `.lead`, `.agent`), or `.person` after the person edited it.
    public var author: DeckMemoryAuthor?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var isArchived: Bool { archivedAt != nil }
    public init(id: String, owner: DeckMemoryOwner, topic: String?, title: String, markdown: String, labels: DeckMemoryLabels, path: String,
                author: DeckMemoryAuthor? = nil, createdAt: Date, updatedAt: Date, archivedAt: Date? = nil) {
        self.id = id; self.owner = owner; self.topic = topic; self.title = title; self.markdown = markdown; self.labels = labels; self.path = path
        self.author = author; self.createdAt = createdAt; self.updatedAt = updatedAt; self.archivedAt = archivedAt
    }
}

public struct DeckMemoryHandoffDraft: Sendable {
    public var title: String
    public var markdown: String
    /// The seat that wrote it (plus session, hand and job when the app knows them).
    public var stamp: DeckMemoryStamp
    /// The topic it is about: a topic id or its title. nil = the whole conversation.
    public var topic: String?
    public var author: DeckMemoryAuthor?
    public init(title: String, markdown: String, stamp: DeckMemoryStamp, topic: String? = nil, author: DeckMemoryAuthor? = nil) {
        self.title = title; self.markdown = markdown; self.stamp = stamp; self.topic = topic; self.author = author
    }
}

// MARK: Card

public struct DeckMemoryCard: Hashable, Sendable, Codable {
    public var owner: DeckMemoryOwner
    /// The seat's OWN card, exactly as it is on disk. Never cut. (The category template is `assembledCard`.)
    public var text: String
    public var path: String
    /// Characters in the seat's own text.
    public var characters: Int
    /// Characters the category template adds in front of it at delivery.
    public var sharedCharacters: Int
    /// The size cap for the assembled card (template + own). Set in the category template.
    public var limit: Int
    /// 0 when template + own fit; otherwise how many characters over. Show it; never cut silently.
    public var overBy: Int
    public var updatedAt: Date?
    /// The lines under "## Top rules" in the seat's own card.
    public var topRules: [String]
    public var exists: Bool { updatedAt != nil }
    public var fits: Bool { overBy == 0 }
    public init(owner: DeckMemoryOwner, text: String, path: String, limit: Int, updatedAt: Date?, sharedCharacters: Int = 0) {
        self.owner = owner; self.text = text; self.path = path; self.limit = limit; self.updatedAt = updatedAt
        self.sharedCharacters = sharedCharacters
        characters = text.count; overBy = max(0, text.count + sharedCharacters - limit); topRules = DeckMemoryCard.topRules(in: text)
    }
    public static let defaultLimit = 6000
    /// The heading the project guide's "What it is" line is kept under, in the project's own card.
    public static let projectAboutHeading = "What this project is"
    /// The card text with the section under `## heading` set to `body` (added at the end when it is not there; taken
    /// out when `body` is empty). Every other line stays exactly as it was.
    public static func replacingSection(_ heading: String, with body: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let wanted = heading.lowercased()
        let start = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#") && trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start {
            var end = start + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("#") { end += 1 }
            let replacement = clean.isEmpty ? [] : [lines[start], clean, ""]
            lines.replaceSubrange(start..<end, with: replacement)
            return lines.joined(separator: "\n")
        }
        guard !clean.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .newlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + "## " + heading + "\n" + clean + "\n"
    }
    /// Kept so older call sites compile. There is no short tier any more: the cap comes from the category template.
    public static let shortLimit = 1500
    /// Bullet or plain lines under a heading called "Top rules" (any level, any case), up to the next heading.
    public static func topRules(in text: String) -> [String] {
        var inside = false, rules: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let name = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                inside = name == "top rules" || name == "always"
                continue
            }
            guard inside, !line.isEmpty else { continue }
            rules.append(line)
        }
        return rules
    }
}

// MARK: Playbook

/// One line of the playbook: for this kind of job, start the session like this.
public struct DeckMemoryPlaybookRow: Identifiable, Hashable, Sendable, Codable {
    public var id: String { DeckMemoryOwner.slug(jobKind) }
    public var jobKind: String
    /// "claude", "codex" or "gemini" ("" = no preference).
    public var ai: String
    public var model: String
    public var effort: String
    public var permission: String
    public var instructions: String
    public init(jobKind: String, ai: String = "", model: String = "", effort: String = "", permission: String = "", instructions: String = "") {
        self.jobKind = jobKind; self.ai = ai; self.model = model; self.effort = effort; self.permission = permission; self.instructions = instructions
    }
    /// The row used when no job kind matches.
    public static let fallbackKinds = ["default", "anything else", "everything else", "other"]
}

public struct DeckMemoryPlaybook: Hashable, Sendable, Codable {
    public var owner: DeckMemoryOwner
    public var rows: [DeckMemoryPlaybookRow]
    /// Free text above the table in playbook.md, kept as written.
    public var preface: String
    public var path: String
    public var updatedAt: Date?
    public init(owner: DeckMemoryOwner, rows: [DeckMemoryPlaybookRow], preface: String = "", path: String, updatedAt: Date?) {
        self.owner = owner; self.rows = rows; self.preface = preface; self.path = path; self.updatedAt = updatedAt
    }
    /// Exact name, then a name contained in the job, then the fallback row.
    public func row(for job: String) -> DeckMemoryPlaybookRow? {
        let wanted = job.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = rows.first(where: { $0.jobKind.lowercased() == wanted }) { return exact }
        if !wanted.isEmpty, let partial = rows.first(where: {
            let kind = $0.jobKind.lowercased()
            return !DeckMemoryPlaybookRow.fallbackKinds.contains(kind) && !kind.isEmpty && (wanted.contains(kind) || kind.contains(wanted))
        }) { return partial }
        return rows.first { DeckMemoryPlaybookRow.fallbackKinds.contains($0.jobKind.lowercased()) }
    }
}

// MARK: Search

public enum DeckMemorySearchKind: String, Sendable, Codable, CaseIterable { case note, diary, topic, card, playbook }
public enum DeckMemorySearchMode: String, Sendable, Codable {
    /// Exact words only. This is the base: build numbers, file names and error codes are found by their words.
    case words
    /// By meaning only (falls back to words when this Mac cannot do it).
    case meaning
    /// Words, with matches by meaning added on top and the two lists merged by rank. An exact word hit can come first by itself.
    case both
}

public struct DeckMemorySearchQuery: Sendable {
    public var text: String
    public var owner: DeckMemoryOwner?
    public var project: String?
    public var session: String?
    public var agent: String?
    public var kinds: Set<DeckMemorySearchKind>?
    public var includeArchived: Bool
    public var mode: DeckMemorySearchMode
    public var limit: Int
    /// Only things said or written in this stretch of time.
    public var since: Date?
    public var until: Date?
    /// Also return notes that were replaced (superseded or merged), below the current ones and labelled.
    /// For a search an AI asked for; leave false for text the app lays down on its own.
    public var includeReplaced: Bool
    public init(_ text: String, owner: DeckMemoryOwner? = nil, project: String? = nil, session: String? = nil, agent: String? = nil,
                kinds: Set<DeckMemorySearchKind>? = nil, includeArchived: Bool = false, mode: DeckMemorySearchMode = .both, limit: Int = 20,
                since: Date? = nil, until: Date? = nil, includeReplaced: Bool = false) {
        self.text = text; self.owner = owner; self.project = project; self.session = session; self.agent = agent
        self.kinds = kinds; self.includeArchived = includeArchived; self.mode = mode; self.limit = limit
        self.since = since; self.until = until; self.includeReplaced = includeReplaced
    }
}

public struct DeckMemorySearchHit: Identifiable, Hashable, Sendable, Codable {
    public var id: String { kind.rawValue + ":" + ref }
    public var kind: DeckMemorySearchKind
    /// Note id, diary row id (as text), topic id, or the owner key for a card/playbook.
    public var ref: String
    public var title: String
    public var snippet: String
    public var labels: DeckMemoryLabels
    /// The file, relative to the memory root (nil for diary rows).
    public var path: String?
    public var score: Double
    /// "words", "meaning", or "both" when the two agreed.
    public var matchedBy: DeckMemorySearchMode
    public var archived: Bool
    /// For a note that is no longer current: a plain line such as "replaced on 2026-10-10 by “All new work to Codex”".
    public var standing: String?
    /// For a short diary reply ("ok, do that") that only makes sense with its neighbours: the messages just before and
    /// after it in the same conversation, so the hit can be read on its own.
    public var context: String?
    public init(kind: DeckMemorySearchKind, ref: String, title: String, snippet: String, labels: DeckMemoryLabels, path: String?,
                score: Double, matchedBy: DeckMemorySearchMode, archived: Bool = false, standing: String? = nil, context: String? = nil) {
        self.kind = kind; self.ref = ref; self.title = title; self.snippet = snippet; self.labels = labels; self.path = path
        self.score = score; self.matchedBy = matchedBy; self.archived = archived; self.standing = standing; self.context = context
    }
}

public struct DeckMemorySearchResult: Sendable, Codable, Hashable {
    public var hits: [DeckMemorySearchHit]
    /// Whether matching by meaning took part.
    public var usedMeaning: Bool
    /// A plain sentence when meaning search was asked for but could not run.
    public var notice: String?
    public init(hits: [DeckMemorySearchHit], usedMeaning: Bool, notice: String? = nil) { self.hits = hits; self.usedMeaning = usedMeaning; self.notice = notice }
}

// MARK: Questions for you

public struct DeckMemoryQuestion: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public var owner: DeckMemoryOwner
    public var text: String
    /// Why it is being asked (the two notes that disagree, say).
    public var context: String
    /// Note ids or paths it is about.
    public var refs: [String]
    public var askedAt: Date
    public var answer: String?
    public var answeredAt: Date?
    /// When the person waved it away. A dismissed question is kept (the Dismissed list) and is never raised again.
    public var dismissedAt: Date?
    public var isOpen: Bool { answeredAt == nil && dismissedAt == nil }
    public var isDismissed: Bool { dismissedAt != nil }
    public var state: DeckMemoryQuestionState { dismissedAt != nil ? .dismissed : answeredAt != nil ? .answered : .open }
    public init(id: Int64, owner: DeckMemoryOwner, text: String, context: String = "", refs: [String] = [], askedAt: Date,
                answer: String? = nil, answeredAt: Date? = nil, dismissedAt: Date? = nil) {
        self.id = id; self.owner = owner; self.text = text; self.context = context; self.refs = refs; self.askedAt = askedAt
        self.answer = answer; self.answeredAt = answeredAt; self.dismissedAt = dismissedAt
    }
}

public enum DeckMemoryQuestionState: String, Sendable, Codable, CaseIterable {
    case open, answered, dismissed
    public var title: String { self == .open ? "Open" : self == .answered ? "Answered" : "Dismissed" }
}

// MARK: Owners, folder, import

public struct DeckMemoryOwnerInfo: Identifiable, Hashable, Sendable, Codable {
    public var id: String { owner.key }
    public var owner: DeckMemoryOwner
    /// The seat's title (given when the seat was made: the role's title, never the hire's name), or the folder name.
    public var name: String
    /// The folder, relative to the memory root.
    public var folder: String
    public var hasCard: Bool
    /// Live notes and open topics in this seat.
    public var notes: Int
    public var topics: Int
    /// Diary rows stamped with this seat.
    public var diary: Int
    /// For a short-lived helper seat: the seat it works under (its notes fold back into it when it closes).
    public var parent: DeckMemoryOwner?
    public var category: DeckMemoryCategory? { owner.category }
    /// Something has been remembered here (so a vacant seat still shows "has memory").
    public var hasMemory: Bool { notes > 0 || topics > 0 || diary > 0 }
    public var isHelper: Bool { parent != nil }
    public init(owner: DeckMemoryOwner, name: String, folder: String, hasCard: Bool, notes: Int, topics: Int, diary: Int = 0, parent: DeckMemoryOwner? = nil) {
        self.owner = owner; self.name = name; self.folder = folder; self.hasCard = hasCard; self.notes = notes; self.topics = topics; self.diary = diary
        self.parent = parent
    }
}

public struct DeckMemoryLocation: Hashable, Sendable, Codable {
    /// The memory folder in use now.
    public var root: URL
    /// Where it would be if never moved: "Terminal Deck Memory" inside the app's own data folder, for every build.
    public var defaultRoot: URL
    /// Folders it was moved away from. They are left in place as archives.
    public var previousRoots: [URL]
    public var isDefault: Bool { root.standardizedFileURL == defaultRoot.standardizedFileURL }
    public init(root: URL, defaultRoot: URL, previousRoots: [URL] = []) { self.root = root; self.defaultRoot = defaultRoot; self.previousRoots = previousRoots }
}

public struct DeckMemoryMoveReport: Hashable, Sendable, Codable {
    public var from: URL
    public var to: URL
    public var files: Int
    public var bytes: Int64
    /// Every copied file was read back and matched.
    public var verified: Bool
    public init(from: URL, to: URL, files: Int, bytes: Int64, verified: Bool) { self.from = from; self.to = to; self.files = files; self.bytes = bytes; self.verified = verified }
}

public struct DeckMemoryImportReport: Hashable, Sendable, Codable {
    public var source: URL
    public var owner: DeckMemoryOwner
    /// The folder the copies went to, relative to the memory root.
    public var folder: String
    public var imported: Int
    /// Already imported before, and the source changed since: the copy was refreshed (the old copy is archived).
    public var updated: Int
    public var unchanged: Int
    /// Files left out, each with a plain reason.
    public var skipped: [String]
    public var noteIDs: [String]
    /// Every copy was read back and matched its source text.
    public var verified: Bool
    public init(source: URL, owner: DeckMemoryOwner, folder: String, imported: Int = 0, updated: Int = 0, unchanged: Int = 0,
                skipped: [String] = [], noteIDs: [String] = [], verified: Bool = false) {
        self.source = source; self.owner = owner; self.folder = folder; self.imported = imported; self.updated = updated
        self.unchanged = unchanged; self.skipped = skipped; self.noteIDs = noteIDs; self.verified = verified
    }
}

/// A short-lived helper seat folded back into its parent seat.
public struct DeckMemoryFoldReport: Hashable, Sendable, Codable {
    public var from: DeckMemoryOwner
    public var into: DeckMemoryOwner
    /// Notes that moved (each keeps its id, its history and a `folded_from` label).
    public var notes: Int
    public var topics: Int
    public init(from: DeckMemoryOwner, into: DeckMemoryOwner, notes: Int, topics: Int) { self.from = from; self.into = into; self.notes = notes; self.topics = topics }
}

public struct DeckMemoryReindexReport: Hashable, Sendable, Codable {
    public var scanned: Int
    public var added: Int
    public var changed: Int
    /// Files that are gone from disk. Their index rows are marked missing, never dropped.
    public var missing: Int
    public init(scanned: Int = 0, added: Int = 0, changed: Int = 0, missing: Int = 0) { self.scanned = scanned; self.added = added; self.changed = changed; self.missing = missing }
}

// MARK: Live changes

/// Posted after every change, whether it came from the app, a tool, or an edit made outside the app.
public struct DeckMemoryChange: Hashable, Sendable, Codable {
    public enum Area: String, Sendable, Codable, CaseIterable {
        case card, notes, diary, board, topics, playbook, questions, settings, documents, folder, index, templates
    }
    public var area: Area
    public var owner: DeckMemoryOwner?
    /// Note id, diary row id, board row id, topic id, settings key.
    public var ref: String?
    public var at: Date
    public init(area: Area, owner: DeckMemoryOwner? = nil, ref: String? = nil, at: Date = Date()) {
        self.area = area; self.owner = owner; self.ref = ref; self.at = at
    }
}

public extension Notification.Name {
    /// Posted on the main thread; `userInfo["change"]` is the `DeckMemoryChange`.
    static let deckMemoryChanged = Notification.Name("dev.terminaldeck.deck-memory.changed")
    /// Posted on the main thread when a seat's AI presents a handoff with the `handoff.present` tool:
    /// `userInfo["owner"]` is the seat's key (String), `userInfo["id"]` the handoff's id (String). Open the reading canvas on it.
    static let deckMemoryHandoffPresented = Notification.Name("dev.terminaldeck.deck-memory.handoff-presented")
}

/// The Deck Memory tools an AI can call (MEMORY-SPEC section 5). They stay listed although the old Memory
/// page's own tools (memory.read, memory.graph) are paused.
public enum DeckMemoryToolNames {
    public static let ids: Set<String> = ["memory.search", "memory.card.read", "memory.board.read", "memory.diary.read", "memory.note.add",
                                          "memory.note.archive", "memory.topic.update", "playbook.read", "playbook.update",
                                          // The helper's and the tidy-up's own tools (M2 FLOW). Hidden by the old pause until 11 Oct 07:00:
                                          // they ran when called by name, but no AI could look up their arguments.
                                          "memory.helper.status", "memory.helper.run", "memory.tidy.run", "memory.checklist.read", "memory.checklist.add"]
    /// The old paused Memory page's own tools: the only `memory.*` names that stay hidden.
    public static let pausedPageTools: Set<String> = ["memory.read", "memory.graph"]
    /// Every `memory.*` tool is Deck Memory's (the nine above, the helper's five, the profile's own controls, and any
    /// added later) except the paused page's. Turned around on 11 Oct 10:58: a list of allowed names hid each new tool
    /// until someone remembered to add it (it happened twice in one morning).
    public static func contains(_ name: String) -> Bool {
        if ids.contains(name) || ids.contains(where: { $0.replacingOccurrences(of: ".", with: "_") == name }) { return true }
        guard name.hasPrefix("memory.") || name.hasPrefix("memory_") else { return false }
        return !pausedPageTools.contains(name) && !pausedPageTools.contains(where: { $0.replacingOccurrences(of: ".", with: "_") == name })
    }
}

/// Setting names the lanes share (`DeckMemoryStoring.value/setValue`). Values are plain text.
public enum DeckMemoryKeys {
    /// Moved to the category template (`helperAI`, `helperModel`). Kept so older call sites compile.
    public static let helperAI = "helper.ai"
    public static let helperModel = "helper.model"
    /// The last diary row id the helper has read for one session: `helperCursor + "." + sessionID`.
    public static let helperCursor = "helper.cursor"
    public static let helperLastRun = "helper.last-run"
    public static let tidyLastRun = "tidy.last-run"
    /// The card size cap of a project's shared card (characters). Seats take theirs from the category template.
    public static let cardLimit = "card.limit"
    /// The seat's title, kept when the seat was made.
    public static let seatTitle = "seat.title"
    /// A helper seat's parent seat (an owner key).
    public static let seatParent = "seat.parent"
    /// Where a closed helper seat's notes went (an owner key).
    public static let seatFoldedInto = "seat.folded-into"
}

public struct DeckMemoryError: Error, LocalizedError, Hashable, Sendable {
    public enum Code: String, Sendable {
        case unavailable, notFound, invalid, proofRequired, conflict, moveFailed, io
    }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
