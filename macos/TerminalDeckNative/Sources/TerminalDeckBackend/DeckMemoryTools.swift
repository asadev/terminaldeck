import Foundation
import TerminalDeckNativeCore

/// The Deck Memory tools (MEMORY-SPEC section 5), behind the same door as every other deck tool:
/// the caller is identified by the app, reads are free, changes ask first, every call is logged.
/// The AI never chooses whose memory it writes to: the seat comes from who is calling.
public enum DeckMemoryTools {
    public static let ownerID = "native.deck-memory-tools"
    public static let area = "deck-memory"
    /// Tools a terminal session may call (its grant is a positive list). `memory.search` is already on that list.
    public static let sessionToolIDs = ["memory.card.read", "memory.board.read", "memory.diary.read", "memory.note.add", "memory.note.archive",
                                        "memory.topic.update", "playbook.read", "handoff.present", JobFlowWords.toolID]
    public static var sessionToolNames: Set<String> { Set(sessionToolIDs.flatMap { [$0, $0.replacingOccurrences(of: ".", with: "_")] }) }
    /// Every tool this file registers (`memory.search` is the existing tool, extended in BackendDeckToolsAppMemory).
    public static let toolIDs = sessionToolIDs + ["playbook.update"]
    /// Memory tools that stay listed although the old Memory page's tools are paused.
    public static let discoverableIDs = Set(toolIDs + ["memory.search"])

    private typealias K = BackendDeckToolsAppKit

    /// Who is calling, as the app knows it.
    struct Caller: Sendable {
        var stamp: DeckMemoryStamp
        /// Hoot and connected AI apps see the whole memory; a session sees its own seat and its project.
        var seesAll: Bool
        var kind: BackendDeckToolsAppCaller.Kind
        var author: DeckMemoryAuthor
    }
    static func caller(_ access: BackendDeckToolsAppAccess, _ context: BackendMCPCallContext) async throws -> Caller {
        let who = try await access.caller(context)
        switch who.kind {
        case .local:
            return .init(stamp: .hoot, seesAll: true, kind: .local, author: .orchestrator)
        case .key:
            return .init(stamp: .init(owner: .hoot, agent: who.keyName.map { "ai-app:" + $0 } ?? "ai-app"), seesAll: true, kind: .key, author: .agent)
        case .session:
            guard who.machineID == nil || who.machineID == "" else { throw K.refused("This session runs on another computer, and the memory is on this one.") }
            guard let id = who.sessionID, !id.isEmpty else { throw K.refused("This session is not one this app is running.") }
            // The seat a session sits in is the app's knowledge (L4's registry), never the session's own claim.
            if var stamp = await DeckMemoryCenter.shared.stamp(forSession: id) {
                stamp.session = stamp.session ?? id
                return .init(stamp: stamp, seesAll: false, kind: .session, author: stamp.owner.category == .lead ? .lead : .agent)
            }
            let session: NativeRPCValue
            do { session = try await access.session(context, id) } catch { throw K.refused("This session is not one this app is running.") }
            let project = session["projectId"].string.flatMap { $0.isEmpty ? nil : $0 }
                ?? DeckMemoryOwner.slug(URL(fileURLWithPath: session["cwd"].string ?? "").lastPathComponent)
            return .init(stamp: .init(owner: .project(project), project: project, session: id, agent: session["provider"].string),
                         seesAll: false, kind: .session, author: .agent)
        default:
            throw K.refused("Memory is read and written on this computer only: by Hoot, by sessions this app runs, and by AI apps the person gave a key to.")
        }
    }
    /// The seat a call is about. Hoot and AI apps may name one (`seat`: "lead:crm", "projects/crm/roles/ios", …);
    /// a session always gets its own, plus (for reading) its project's shared space.
    static func seat(_ args: NativeRPCValue, _ caller: Caller, reading: Bool) throws -> DeckMemoryOwner {
        guard let named = try K.optStr(args, "seat", trimmed: true) else { return caller.stamp.owner }
        guard let owner = DeckMemoryOwner(named) else { throw BackendDeckToolsArgs.bad("seat must look like hoot, lead:<project>, role:<project>/<role>, role:<role> or project:<project>") }
        if caller.seesAll || owner == caller.stamp.owner { return owner }
        if reading, let project = caller.stamp.project, owner == .project(project) { return owner }
        throw K.refused("A session reads and writes its own seat's memory only. Leave seat out.")
    }

    // MARK: Plain values for an AI to read

    static func iso(_ date: Date) -> NativeRPCValue { .string(DeckMemoryFiles.stamp(date)) }
    static func opt(_ text: String?) -> NativeRPCValue { text.map(NativeRPCValue.string) ?? .missing }
    static func labels(_ labels: DeckMemoryLabels) -> [(String, NativeRPCValue)] {
        [("seat", .string(labels.seat)), ("project", opt(labels.project)), ("hand", labels.hand.map(K.n) ?? .missing), ("job", opt(labels.job)),
         ("session", opt(labels.session)), ("date", iso(labels.date))]
    }
    static func wire(_ note: DeckMemoryNote) -> NativeRPCValue {
        K.object([("id", .string(note.id)), ("title", .string(note.title)), ("short", .string(note.listTitle)), ("type", .string(note.type.rawValue)), ("text", .string(note.body))]
                 + labels(note.labels)
                 + [("file", .string(note.path)), ("replaces", opt(note.supersedes)), ("replacedBy", opt(note.supersededBy)),
                    ("archived", note.isArchived ? .bool(true) : .missing), ("archiveReason", opt(note.archiveReason))])
    }
    static func wire(_ row: DeckMemoryBoardRow) -> NativeRPCValue {
        K.object([("id", .string(row.id)), ("kind", .string(row.kind.rawValue)), ("title", .string(row.title)), ("doing", .string(row.doing)),
                  ("lastResult", .string(row.lastResult)), ("resultState", opt(row.state?.rawValue)), ("proof", row.proof.isEmpty ? .missing : .string(row.proof)),
                  ("waitingForThePerson", row.waitingForUser.isEmpty ? .missing : .string(row.waitingForUser))] + labels(row.labels))
    }
    static func wire(_ row: DeckMemoryPlaybookRow) -> NativeRPCValue {
        K.object([("job", .string(row.jobKind)), ("ai", .string(row.ai)), ("model", .string(row.model)), ("effort", .string(row.effort)),
                  ("permission", .string(row.permission)), ("instructions", .string(row.instructions))])
    }
    /// `whole`: Hoot reads the diary as it was said. Anyone else gets it with private parts and secrets taken out.
    static func wire(_ entry: DeckMemoryDiaryEntry, whole: Bool) -> NativeRPCValue {
        K.object([("id", .number(Double(entry.id))), ("role", .string(entry.role.rawValue)), ("saidBy", opt(entry.author?.rawValue)),
                  ("text", .string(whole ? entry.text : DeckMemoryRedaction.forSharing(entry.text))),
                  ("rewound", entry.isRewound ? .string("The person rewound the conversation to before this. It is history, not part of the conversation now.") : .missing)]
                 + labels(entry.labels))
    }
    static func wire(_ hit: DeckMemorySearchHit, whole: Bool) -> NativeRPCValue {
        let snippet = whole || hit.kind != .diary ? hit.snippet : DeckMemoryRedaction.forSharing(hit.snippet)
        return K.object([("kind", .string(hit.kind.rawValue)), ("ref", .string(hit.ref)), ("title", .string(hit.title)), ("snippet", .string(snippet))]
                 + labels(hit.labels) + [("handoff", hit.ref.range(of: "#handoff:").map { .string(String(hit.ref[$0.upperBound...])) } ?? .missing),
                                         ("file", opt(hit.path)), ("foundBy", .string(hit.matchedBy.rawValue)),
                                         ("standing", opt(hit.standing)),
                                         ("around", opt(hit.context.map { whole ? $0 : DeckMemoryRedaction.forSharing($0) })),
                                         ("archived", hit.archived ? .bool(true) : .missing)])
    }

    /// What `memory.search` adds from Deck Memory (notes, diary, topics, cards) for this caller. nil when the store is not open.
    /// The time budget of memory_search's Terminal Deck part: the whole search, then the words-only fallback.
    static let searchSeconds: Double = 12, wordsSeconds: Double = 8
    public static func search(access: BackendDeckToolsAppAccess, context: BackendMCPCallContext, query: String, limit: Int,
                              since: Date? = nil, until: Date? = nil) async -> NativeRPCValue? {
        guard DeckMemory.isReady, let caller = try? await caller(access, context) else { return nil }
        // An AI asked: replaced notes come back too, below the current ones and labelled, so it sees what changed.
        var wanted = DeckMemorySearchQuery(query, limit: limit, since: since, until: until, includeReplaced: true)
        // A session searches its project (every seat in it) or, outside a project, its own seat.
        if !caller.seesAll { if let project = caller.stamp.project { wanted.project = project } else { wanted.owner = caller.stamp.owner } }
        // 30 Oct (Decker: memory_search timed out): the search has a time budget. Matching by meaning reads up to 40,000
        // stored vectors and needs the meaning model; on a busy Mac with little free memory that can take minutes. Past
        // the budget the words alone answer (the full-text index, fast), and the answer says so.
        let store = DeckMemory.store
        var note: String?
        let asked = wanted
        let first = await BackendMCPCallBudget.within(searchSeconds) { try? await store.search(asked) }
        var found = first ?? nil
        if first == nil {   // the budget ran out (a search that failed outright answers nil inside, not here)
            var words = wanted; words.mode = .words
            let byWords = words
            found = await BackendMCPCallBudget.within(wordsSeconds) { try? await store.search(byWords) } ?? nil
            note = "Matching by meaning took too long on this Mac just now, so these are word matches."
        }
        guard let found else { return nil }
        return K.object([("results", .array(found.hits.map { wire($0, whole: caller.kind == .local) })), ("byMeaning", .bool(found.usedMeaning)), ("note", opt(note ?? found.notice)),
                         ("next", .string("memory.diary.read opens the moment around a diary result (pass its ref as id)."))])
    }

    // MARK: The tools

    private struct Spec { let id: String, tier: BackendMCPTier, title: String, description: String, schema: String }
    private static let seatField = #""seat":{"type":"string","description":"Hoot and AI apps only: whose memory, e.g. hoot, lead:<project>, role:<project>/<role>, project:<project>. Leave out for your own."}"#
    private static let specs: [Spec] = [
        .init(id: "memory.card.read", tier: .read, title: "Read a memory card",
              description: "Read your card: the rules shared by everyone of your kind (the template) followed by your seat's own additions, exactly as you are given it at the top of a clean desk. Says how long it is against its size cap.",
              schema: #"{"type":"object","properties":{\#(seatField)},"additionalProperties":false}"#),
        .init(id: "memory.board.read", tier: .read, title: "Read the board",
              description: "Read the board the app keeps from what really happened: each session, agent and task with what it is doing, its last result, the result state (attempted, reported or verified) and what waits for the person. Hoot sees every row; a session sees its project's rows.",
              schema: #"{"type":"object","properties":{"project":{"type":"string","description":"Only this project's rows."},"waitingOnly":{"type":"boolean","description":"Only rows that wait for the person."},"since":{"type":"string","description":"Only rows changed after this ISO date."},"limit":{"type":"number","description":"Most rows, 1-200. Default 60."}},"additionalProperties":false}"#),
        .init(id: "memory.diary.read", tier: .read, title: "Read a moment in the diary",
              description: "Open the moment around one diary row (a memory.search result of kind diary): the messages just before and after it, word for word.",
              schema: #"{"type":"object","properties":{"id":{"type":"number","description":"The diary row id (the ref of a diary search result)."},"before":{"type":"number","description":"Rows before it, 0-40. Default 6."},"after":{"type":"number","description":"Rows after it, 0-40. Default 6."}},"required":["id"],"additionalProperties":false}"#),
        .init(id: "playbook.read", tier: .read, title: "Read the playbook",
              description: "Read the playbook: for each kind of job, which AI, model, effort and permission to start a session with and what it is always told. Pass job to get the one row that applies to a job.",
              schema: #"{"type":"object","properties":{"job":{"type":"string","description":"A job, in a few words. Returns the row that applies."},\#(seatField)},"additionalProperties":false}"#),
        .init(id: "memory.note.add", tier: .act, title: "Add a memory note",
              description: "Write one short note into your seat's memory: a decision, preference, correction, result, open-item, lesson or note. One fact per note, understandable by itself. The app stamps who wrote it and where it belongs; you cannot choose another seat's memory. To replace an older note that is no longer true, pass its id as replaces: the old one is archived and stays linked, nothing is deleted.",
              schema: #"{"type":"object","properties":{"title":{"type":"string","maxLength":200},"short":{"type":"string","maxLength":80,"description":"3 to 6 plain words naming it for a list. Left out, the app makes one."},"text":{"type":"string","maxLength":8000},"type":{"type":"string","enum":["decision","preference","correction","result","open-item","lesson","how-to","note"]},"replaces":{"type":"string","description":"The id of the note this one replaces."},\#(seatField)},"required":["title","text"],"additionalProperties":false}"#),
        .init(id: "memory.topic.update", tier: .act, title: "Update a where-we-are topic",
              description: "Write or replace the 'where we are' note for the piece of work you hold, so a clean desk can carry on: the goal, where it stands now, decisions and why, open items, the next step. It is keyed to your job, so another hand's topic is never overwritten. The earlier text is kept.",
              schema: #"{"type":"object","properties":{"title":{"type":"string","maxLength":200},"text":{"type":"string","maxLength":12000},"done":{"type":"boolean","description":"true closes the topic: it is kept but no longer handed to a clean desk."}},"required":["title","text"],"additionalProperties":false}"#),
        .init(id: "memory.note.archive", tier: .alter, title: "Archive a memory note",
              description: "Put a note of your seat away into the archive, with the reason. Nothing is deleted; the person can bring it back.",
              schema: #"{"type":"object","properties":{"id":{"type":"string"},"reason":{"type":"string","maxLength":400}},"required":["id","reason"],"additionalProperties":false}"#),
        .init(id: "playbook.update", tier: .alter, title: "Change the playbook",
              description: "Add or change playbook rows (job kind to AI, model, effort, permission, standing instructions). Runs at once when the calling AI's permission mode allows it; the action is logged. Rows you do not name are left as they are.",
              schema: #"{"type":"object","properties":{"rows":{"type":"array","maxItems":40,"items":{"type":"object","properties":{"job":{"type":"string"},"ai":{"type":"string","enum":["","claude","codex","gemini"]},"model":{"type":"string"},"effort":{"type":"string"},"permission":{"type":"string"},"instructions":{"type":"string","maxLength":2000}},"required":["job"],"additionalProperties":false}},"remove":{"type":"array","items":{"type":"string"},"description":"Job kinds to take out."},\#(seatField)},"additionalProperties":false}"#),
        // Declared as a read so that no approval card is raised: it only writes a document into the caller's OWN seat's
        // memory (never deleting anything) and opens a reading panel. An AI app holding a key is not a seat and is asked.
        .init(id: "handoff.present", tier: .read, title: "Present a handoff",
              description: "Write the context handoff for a topic (or for the whole conversation) and show it to the person in a reading panel. Call this once, with the finished document; do not also paste the document into your reply. Before writing, gather what you need with the memory tools: the topic's 'where we are' note, the decision notes, and the diary passages (memory.search, memory.diary.read). Write it so another AI or a person can pick the work up cold, with nothing of this chat in view. Use these parts, in this order, each under its own heading: Goal. Where we are now. Decisions made (each with its date). What is done. What is left. Open questions. Files, links and sessions involved. How to continue. Plain Markdown; exact names, paths, ids and dates; never 'as discussed'. The document is saved with the topic in your seat's memory; earlier handoffs stay.",
              schema: #"{"type":"object","properties":{"title":{"type":"string","maxLength":200,"description":"A short title for the document."},"topic":{"type":"string","description":"The topic it is about: its title or id. Leave out, or say whole conversation, when it covers everything."},"markdown":{"type":"string","maxLength":120000,"description":"The whole document, in Markdown."}},"required":["title","markdown"],"additionalProperties":false}"#),
        // Declared as a read: it changes nothing but the line the person sees in the job flow, so it never asks anyone.
        .init(id: JobFlowWords.toolID, tier: .read, title: "Show a rule or skill step in the job flow",
              description: "The person watches a live list of your job. Call this at the moment you apply one of your rules, or reach a step of a skill, so it shows there with a tick: pass rule (a note's id like n-20261011-ab12cd, or the rule's own words as written in your card or notes), or skill (its name) with step (1, 2, 3…) and stepTitle (the step's few words). Report a rule once per job, when you really follow it; report each skill step as you reach it. Nothing else changes and nobody is asked. Only what you report shows as applied.",
              schema: #"{"type":"object","properties":{"rule":{"type":"string","maxLength":2000,"description":"A note id, or the rule's own words."},"skill":{"type":"string","maxLength":200},"step":{"type":"integer","minimum":1,"maximum":200},"stepTitle":{"type":"string","maxLength":200},"detail":{"type":"string","maxLength":400,"description":"Optional: how you applied it, in a few words."}},"additionalProperties":false}"#)
    ]

    public static func definitions(access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try specs.map { spec in
            let tool = try BackendMCPTool(id: spec.id, wireName: spec.id.replacingOccurrences(of: ".", with: "_"), description: spec.description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(spec.schema.utf8)), tier: spec.tier, advertised: false)
            return BackendDeckToolsDefinition(spec: tool, title: spec.title, index: spec.title) { context, args in
                do {
                    guard args.fields != nil else { throw BackendDeckToolsArgs.bad("arguments must be an object") }
                    guard context.allowedTiers.contains(spec.tier) else { throw K.refused("This caller is not permitted to use that tool.") }
                    if context.cancellation.isCancelled { throw CancellationError() }
                    try BackendDeckCoreCatalogueSchema.check(schema: tool.inputSchema, arguments: args)
                    guard DeckMemory.isReady else { throw K.unavailable("Memory") }
                    let caller = try await caller(access, context)
                    let output = try await run(spec.id, args: args, caller: caller, access: access, context: context)
                    // One short line for the chat instead of the whole document; the details ride along beside it.
                    if let line = output["line"].string {
                        return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(line))])], structuredContent: output)
                    }
                    return .value(output)
                } catch is CancellationError { throw CancellationError() }
                catch let error as DeckMemoryError {
                    return BackendDeckToolsMachinesFactory.failureReply(NativeRPCError(code: error.code == .notFound ? "not-found" : "memory", message: error.message))
                }
                catch { return BackendDeckToolsMachinesFactory.failureReply(error) }
            }
        }
    }

    /// Asks first for a change (the usual consent rule), runs it, and writes the action row. Note text is never put in the log.
    private static func gate(_ access: BackendDeckToolsAppAccess, _ context: BackendMCPCallContext, _ id: String, tier: BackendMCPTier,
                             sentence: String, ownerMustAnswer: Bool = false, safe: NativeRPCValue) async throws {
        try await access.authorize(context, id, safe, tier, sentence, ownerMustAnswer)
        if context.cancellation.isCancelled { throw CancellationError() }
    }

    private static func run(_ id: String, args: NativeRPCValue, caller: Caller, access: BackendDeckToolsAppAccess,
                            context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let memory = DeckMemory.store
        // An AI app holding a key is not at the keyboard: its changes always wait for the person's own answer.
        let mustAnswer = caller.kind == .key
        switch id {
        case "memory.card.read":
            let seat = try seat(args, caller, reading: true)
            try await gate(access, context, id, tier: .read, sentence: "Read the memory card of \(seat.key)", safe: K.object([("seat", .string(seat.key))]))
            let card = try await memory.assembledCard(seat)
            let value = K.object([("seat", .string(seat.key)), ("category", opt(seat.category?.rawValue)), ("card", .string(card.text)),
                ("sharedByTheCategory", .string(card.shared)), ("thisSeatsOwn", .string(card.own)),
                ("size", .string("\(card.characters) of \(card.limit) characters" + (card.overBy > 0 ? ", over by \(card.overBy)" : "")))])
            try await access.record(context, id, K.object([("seat", .string(seat.key))]), K.object([("characters", K.n(card.characters))]))
            return value
        case "memory.board.read":
            let project = try K.optStr(args, "project", trimmed: true), limit = try BackendDeckToolsArgs.optInt(args, "limit", 60, 1, 200)
            if let project, !caller.seesAll, project != caller.stamp.project { throw K.refused("A session reads its own project's rows. Leave project out.") }
            let since = try K.optStr(args, "since", trimmed: true).map { text -> Date in
                guard let date = DeckMemoryFiles.date(text) else { throw BackendDeckToolsArgs.bad("since must be an ISO date, like 2026-10-11 or 2026-10-11T08:00:00Z") }
                return date
            }
            try await gate(access, context, id, tier: .read, sentence: "Read the board", safe: K.object([("project", opt(project))]))
            var query = DeckMemoryBoardQuery(owner: caller.seesAll ? nil : caller.stamp.owner, project: project,
                                             waitingOnly: try BackendDeckToolsArgs.optBool(args, "waitingOnly", false), changedSince: since, limit: limit)
            // A session outside any seat (a plain session) still sees its project's rows.
            if !caller.seesAll, case .project = caller.stamp.owner { query.owner = caller.stamp.owner }
            let rows = try await memory.board(query)
            try await access.record(context, id, K.object([("project", opt(project))]), K.object([("rows", K.n(rows.count))]))
            return K.object([("rows", .array(rows.map(wire))), ("states", .string("attempted = tried, nobody confirmed. reported = the worker says it is done. verified = checked, with the proof named."))])
        case "memory.diary.read":
            guard let number = args["id"].number, number >= 1, number.rounded() == number else { throw BackendDeckToolsArgs.bad("id must be a diary row id (a whole number)") }
            let before = try BackendDeckToolsArgs.optInt(args, "before", 6, 0, 40), after = try BackendDeckToolsArgs.optInt(args, "after", 6, 0, 40)
            try await gate(access, context, id, tier: .read, sentence: "Read a moment in the diary", safe: K.object([("id", .number(number))]))
            let rows = try await memory.diary(around: Int64(number), before: before, after: after)
            // A session opens moments of its own project or seat only.
            if !caller.seesAll, let middle = rows.first(where: { $0.id == Int64(number) }) {
                let mine = middle.labels.owner == caller.stamp.owner || (caller.stamp.project != nil && middle.labels.project == caller.stamp.project)
                guard mine else { throw K.refused("That moment belongs to another project's memory.") }
            }
            try await access.record(context, id, K.object([("id", .number(number))]), K.object([("rows", K.n(rows.count))]))
            return K.object([("rows", .array(rows.map { wire($0, whole: caller.kind == .local) }))])
        case "playbook.read":
            var seat = try seat(args, caller, reading: true)
            // An agent seat keeps no playbook: it reads its lead's, or Hoot's when its project has no lead.
            if !seat.hasPlaybook { seat = seat.projectID.map(DeckMemoryOwner.lead) ?? .hoot }
            try await gate(access, context, id, tier: .read, sentence: "Read the playbook", safe: K.object([("seat", .string(seat.key))]))
            if let job = try K.optStr(args, "job", trimmed: true) {
                let row = try await memory.playbookRow(seat, job: job)
                try await access.record(context, id, K.object([("seat", .string(seat.key))]), K.object([("found", .bool(row != nil))]))
                return K.object([("seat", .string(seat.key)), ("job", .string(job)), ("row", row.map(wire) ?? .null)])
            }
            var book = try await memory.playbook(seat)
            if book.rows.isEmpty, seat != .hoot { seat = .hoot; book = try await memory.playbook(.hoot) }
            try await access.record(context, id, K.object([("seat", .string(seat.key))]), K.object([("rows", K.n(book.rows.count))]))
            return K.object([("seat", .string(seat.key)), ("rows", .array(book.rows.map(wire)))])
        case "memory.note.add":
            let seat = try seat(args, caller, reading: false)
            let title = try K.str(args, "title", trimmed: true), text = try K.str(args, "text")
            let type = DeckMemoryNoteType(rawValue: try K.optStr(args, "type", trimmed: true) ?? "note")
            let replaces = try K.optStr(args, "replaces", trimmed: true)
            if let replaces {
                guard let old = try await memory.note(id: replaces) else { throw BackendDeckToolsArgs.bad("there is no note with the id \(replaces)") }
                guard caller.seesAll || old.labels.owner == seat else { throw K.refused("That note belongs to another seat, so this session cannot replace it.") }
            }
            let safe = K.object([("seat", .string(seat.key)), ("title", .string(title)), ("type", .string(type.rawValue)), ("replaces", opt(replaces)), ("characters", K.n(text.count))])
            try await gate(access, context, id, tier: .act, sentence: (replaces == nil ? "Add the memory note “\(title)”" : "Replace a memory note with “\(title)”") + " in \(seat.key)",
                           ownerMustAnswer: mustAnswer, safe: safe)
            var stamp = caller.stamp; stamp.owner = seat; stamp.project = seat.projectID ?? (seat == caller.stamp.owner ? caller.stamp.project : nil)
            // An AI wrote this: it never counts as the person's own words, whatever the text claims.
            let note = try await memory.addNote(.init(title: title, body: text, type: type, stamp: stamp, supersedes: replaces,
                                                      source: caller.kind == .key ? "ai-app" : "agent", author: caller.author,
                                                      shortTitle: try K.optStr(args, "short", trimmed: true)))
            try await access.record(context, id, safe, K.object([("id", .string(note.id))]))
            var value = wire(note)
            if let same = note.duplicateOf { value = value.setting("alreadyStored", .string("This seat already holds the same text as note \(same); nothing new was written.")) }
            if let why = note.notReplaced { value = value.setting("notReplaced", .string(why)) }
            return value
        case "memory.topic.update":
            let seat = caller.stamp.owner
            guard seat.isSeat else { throw K.refused("This session holds no seat, so it keeps no 'where we are' topic. Its messages are in the diary all the same.") }
            let title = try K.str(args, "title", trimmed: true), text = try K.str(args, "text")
            let done = try BackendDeckToolsArgs.optBool(args, "done", false)
            let safe = K.object([("seat", .string(seat.key)), ("title", .string(title)), ("job", opt(caller.stamp.job)), ("characters", K.n(text.count))])
            try await gate(access, context, id, tier: .act, sentence: "Update the topic “\(title)” in \(seat.key)", ownerMustAnswer: mustAnswer, safe: safe)
            var topic = try await memory.updateTopic(seat, title: title, body: text, stamp: caller.stamp)
            if done { topic = try await memory.setTopic(seat, id: topic.id, open: false) }
            try await access.record(context, id, safe, K.object([("id", .string(topic.id))]))
            return K.object([("id", .string(topic.id)), ("title", .string(topic.title)), ("open", .bool(topic.open)), ("file", .string(topic.path)),
                             ("size", .string("\(topic.characters) of \(DeckMemoryTopic.defaultLimit) characters" + (topic.overBy > 0 ? ", over by \(topic.overBy): move detail into notes" : "")))]
                            + labels(topic.labels))
        case "memory.note.archive":
            let noteID = try K.str(args, "id", trimmed: true), reason = try K.str(args, "reason", trimmed: true)
            guard let note = try await memory.note(id: noteID) else { throw BackendDeckToolsArgs.bad("there is no note with the id \(noteID)") }
            guard caller.seesAll || note.labels.owner == caller.stamp.owner else { throw K.refused("That note belongs to another seat, so this session cannot archive it.") }
            let safe = K.object([("id", .string(noteID)), ("seat", .string(note.labels.seat)), ("title", .string(note.title))])
            try await gate(access, context, id, tier: .alter, sentence: "Archive the memory note “\(note.title)” (\(reason))", ownerMustAnswer: mustAnswer, safe: safe)
            let archived = try await memory.archiveNote(id: noteID, reason: reason, replacedBy: nil)
            try await access.record(context, id, safe, K.object([("archived", .bool(true))]))
            return wire(archived)
        case "playbook.update":
            var seat = try seat(args, caller, reading: false)
            if !seat.hasPlaybook { seat = seat.projectID.map(DeckMemoryOwner.lead) ?? .hoot }
            guard caller.seesAll || seat == caller.stamp.owner else { throw K.refused("Only Hoot, or the lead whose playbook it is, may propose a change to it.") }
            let incoming = try (args["rows"].elements ?? []).map { row -> DeckMemoryPlaybookRow in
                let job = (row["job"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !job.isEmpty else { throw BackendDeckToolsArgs.bad("every row needs a job") }
                return .init(jobKind: job, ai: row["ai"].string ?? "", model: row["model"].string ?? "", effort: row["effort"].string ?? "",
                             permission: row["permission"].string ?? "", instructions: row["instructions"].string ?? "")
            }
            let remove = Set((args["remove"].elements ?? []).compactMap(\.string).map(DeckMemoryOwner.slug))
            guard !incoming.isEmpty || !remove.isEmpty else { throw BackendDeckToolsArgs.bad("pass rows to add or change, or remove") }
            // A permission wider than the person's own choice is theirs to set, never an AI's.
            if let wide = incoming.first(where: { BackendHootChatStore.bypassModes.contains($0.permission) || $0.permission.lowercased().contains("bypass") }) {
                throw K.refused("Only the person can put a bypass permission into the playbook (row “\(wide.jobKind)”). Propose the row without it.", code: "not-granted")
            }
            let current = try await memory.playbook(seat)
            var rows = current.rows.filter { !remove.contains($0.id) }
            for row in incoming {
                if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row } else { rows.append(row) }
            }
            let changed = incoming.map(\.jobKind) + remove.map { "remove " + $0 }
            let safe = K.object([("seat", .string(seat.key)), ("rows", K.strings(changed))])
            // The playbook decides how sessions are started, so the person answers this one whoever asks.
            try await gate(access, context, id, tier: .alter, sentence: "Change the playbook of \(seat.key): " + changed.joined(separator: ", "), ownerMustAnswer: true, safe: safe)
            let saved = try await memory.savePlaybook(seat, rows: rows, preface: nil)
            try await access.record(context, id, safe, K.object([("rows", K.n(saved.rows.count))]))
            return K.object([("seat", .string(seat.key)), ("rows", .array(saved.rows.map(wire)))])
        case "handoff.present":
            let seat = caller.stamp.owner
            guard seat.isSeat else { throw K.refused("This session holds no seat, so it keeps no handoffs. Its messages are in the diary all the same.") }
            let title = try K.str(args, "title", trimmed: true), markdown = try K.str(args, "markdown")
            var topic = try K.optStr(args, "topic", trimmed: true)
            if let named = topic, ["whole conversation", "the whole conversation", "everything", "all"].contains(named.lowercased()) { topic = nil }
            let safe = K.object([("seat", .string(seat.key)), ("title", .string(title)), ("topic", opt(topic)), ("characters", K.n(markdown.count))])
            try await gate(access, context, id, tier: mustAnswer ? .act : .read, sentence: "Present the handoff “\(title)”", ownerMustAnswer: mustAnswer, safe: safe)
            // The seat's own AI wrote this document; that is what the author says.
            let saved = try await memory.saveHandoff(.init(title: title, markdown: markdown, stamp: caller.stamp, topic: topic, author: caller.author))
            let ownerKey = seat.key, handoffID = saved.id
            await BackendMemoryEvents.shared.publish("deck-memory:handoff-presented", arguments: [.string(ownerKey), .string(handoffID)])
            try await access.record(context, id, safe, K.object([("id", .string(saved.id))]))
            var about = saved.title
            if let kept = saved.topic { about = (try? await memory.topic(seat, id: kept))?.title ?? topic ?? kept }
            return K.object([("line", .string("Handoff ready: " + about)), ("id", .string(saved.id)), ("title", .string(saved.title)),
                             ("topic", opt(saved.topic)), ("file", .string(saved.path))])
        case JobFlowWords.toolID:
            return try await applied(args, caller: caller, access: access, context: context)
        default:
            throw K.unavailable(id)
        }
    }

    // MARK: The job flow (Asad, 12 Oct: rules with a green tick, skill steps one by one)

    /// `flow.applied`: one line in the person's job flow. Hoot's own report is its chat's tool call; an agent's is kept by
    /// the app with the task its session works on, so it shows under that agent in Hoot's flow.
    static func applied(_ args: NativeRPCValue, caller: Caller, access: BackendDeckToolsAppAccess, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let rule = try K.optStr(args, "rule", trimmed: true), skill = try K.optStr(args, "skill", trimmed: true)
        let stepTitle = try K.optStr(args, "stepTitle", trimmed: true), detail = try K.optStr(args, "detail", trimmed: true)
        let step = args["step"].number.flatMap { $0 >= 1 && $0 == $0.rounded() && $0 <= 200 ? Int($0) : nil }
        guard rule != nil || skill != nil else { throw BackendDeckToolsArgs.bad("pass rule (a note id or the rule's words) or skill (with step)") }
        let safe = K.object([("rule", rule == nil ? .missing : .bool(true)), ("skill", opt(skill)), ("step", step.map(K.n) ?? .missing)])
        try await gate(access, context, JobFlowWords.toolID, tier: .read, sentence: "Show a step in the job flow", safe: safe)
        var lines: [String] = [], value: [(String, NativeRPCValue)] = []
        var entries: [JobFlowEntry] = []
        let now = access.now(), session = caller.kind == .session ? caller.stamp.session : nil
        var who = caller.kind == .local ? "Hoot" : caller.stamp.agent ?? caller.stamp.owner.key
        if let session {
            if let known = await BackendJobFlowLog.shared.task(forSession: session), !known.agent.isEmpty { who = known.agent }
            else if let title = (try? await access.session(context, session))?["title"].string, !title.isEmpty { who = title }
        }
        if let rule {
            let found = await resolveRule(rule, owner: caller.stamp.owner, memory: DeckMemory.store)
            lines.append(JobFlowWords.line(kind: .rule, title: found.title, step: nil, stepTitle: nil))
            value.append(("rule", K.object([("id", opt(found.id)), ("title", .string(found.title)), ("rule", .string(found.full)),
                                             ("matched", .bool(found.matched))])))
            if let session {
                entries.append(.init(at: now, session: session, who: who, seat: caller.stamp.owner.key, kind: .rule, ruleID: found.id,
                                     title: found.title, full: found.full, detail: detail))
            }
        }
        if let skill {
            lines.append(JobFlowWords.line(kind: .skill, title: skill, step: step, stepTitle: stepTitle))
            value.append(("skill", K.object([("name", .string(skill)), ("step", step.map(K.n) ?? .missing), ("stepTitle", opt(stepTitle))])))
            if let session {
                entries.append(.init(at: now, session: session, who: who, seat: caller.stamp.owner.key, kind: .skill, title: skill,
                                     step: step, stepTitle: stepTitle, detail: detail))
            }
        }
        for entry in entries { await BackendJobFlowLog.shared.record(entry) }
        try await access.record(context, JobFlowWords.toolID, safe, K.object([("shown", .bool(true))]))
        return K.object([("line", .string(lines.joined(separator: "\n")))] + value)
    }

    /// Which rule the AI meant: a note by id; else one of the seat's top rules (its card and template) with the same
    /// words; else the note whose words match best; else its own words. The short title is what the flow shows.
    static func resolveRule(_ given: String, owner: DeckMemoryOwner, memory: any DeckMemoryStoring) async -> (id: String?, title: String, full: String, matched: Bool) {
        let text = given.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^n-\d{8}-[a-z0-9]+$"#, options: .regularExpression) != nil, let note = try? await memory.note(id: text) {
            return (note.id, note.listTitle, note.title + (note.body.isEmpty ? "" : "\n\n" + note.body), true)
        }
        let key = DeckMemoryShortTitle.ruleKey(text)
        func words(_ value: String) -> Set<String> {
            Set(value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        }
        let wanted = words(text)
        func close(_ candidate: String) -> Bool {
            let other = DeckMemoryShortTitle.ruleKey(candidate)
            if other == key || (key.count >= 12 && (other.contains(key) || key.contains(other))) { return true }
            guard wanted.count >= 3 else { return false }
            return Double(wanted.intersection(words(candidate)).count) / Double(wanted.count) >= 0.6
        }
        if let card = try? await memory.assembledCard(owner), let rule = card.topRules.first(where: close) {
            let titles = await DeckMemoryShortTitles.ruleTitles(memory)
            return (nil, DeckMemoryShortTitles.title(forRule: rule, in: titles), rule, true)
        }
        if let found = try? await memory.search(.init(text, owner: owner, kinds: [.note], limit: 3)) {
            for hit in found.hits where !hit.archived {
                guard let note = try? await memory.note(id: hit.ref), close(note.title + " " + note.body) || close(note.title) else { continue }
                return (note.id, note.listTitle, note.title + (note.body.isEmpty ? "" : "\n\n" + note.body), true)
            }
        }
        return (nil, DeckMemoryShortTitle.fallback(text), text, false)
    }
}
