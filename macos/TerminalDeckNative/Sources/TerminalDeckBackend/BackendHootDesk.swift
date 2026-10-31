import Foundation
import TerminalDeckNativeCore

/// One message of Hoot's visible chat, as the desk hands it back to a clean desk.
public struct BackendHootDeskMessage: Sendable, Equatable {
    public var fromPerson: Bool
    public var text: String
    /// Who wrote it when it was neither the person nor Hoot ("The app (task)"): never shown as the person's words.
    public var label: String?
    public init(fromPerson: Bool, text: String, label: String? = nil) { self.fromPerson = fromPerson; self.text = text; self.label = label }
}

/// What goes at the top of Hoot's desk when its CLI starts.
public struct BackendHootDeskStart: Sendable, Equatable {
    public var text: String
    /// How many characters the card is over its cap (0 = fits). The card is still given whole.
    public var cardOverBy: Int
    public var memoryReady: Bool
    /// What did not fit at the top of the desk and was left out whole (it stays reachable through the memory tools).
    public var leftOut: [String] = []
}

/// Hoot's desk (Deck Memory, design-2026-10-10/MEMORY-SPEC.md): what the app puts in front of Hoot.
///  - the card, the open topics and the board at the top of every clean desk (start instructions),
///  - a few hidden lines with every message.
/// The app never clears Hoot's desk on its own and never starts Hoot on a fresh conversation to empty it (Asad,
/// 28 Oct 2026: the planned refresh, its Refresh now button and the memory.refresh.now tool are gone). The visible
/// chat is Hoot's own event store; the desk never touches it.
public actor BackendHootDesk {
    /// The last messages a clean desk gets back: as many recent ones as fit this many characters.
    public static let tailBudget = 6_000
    /// The card, topics and board at the top of a desk fit this many characters (about a twentieth of a small desk).
    public static let openingLimit = 40_000
    public static let tailMessages = 12
    public static let messageCap = 12_000

    public struct Hooks: Sendable {
        public var memory: @Sendable () -> any DeckMemoryStoring = { DeckMemory.store }
        public var log: @Sendable (String) -> Void = { NSLog("[native Hoot] desk: %@", $0) }
        public var now: @Sendable () -> Date = { Date() }
        public init() {}
    }

    private var hooks: Hooks
    /// When Hoot was last told what is on the board (desk start or his last message).
    private var briefedAt: Date?
    /// The card as Hoot last got it, so an edit made while the desk is open reaches him with his next message.
    private var cardSeen: String?
    /// The open topics laid down when this desk started.
    private var topicsOnDesk: Set<String> = []

    public init(hooks: Hooks = Hooks()) { self.hooks = hooks }
    public func bind(_ hooks: Hooks) { self.hooks = hooks }

    // MARK: The top of the desk

    /// Called each time Hoot's CLI starts. `fresh`: the CLI has no conversation of its own to
    /// continue (first start, a new chat, or a rewind), so the last messages go with it.
    public func start(fresh: Bool, recent: [BackendHootDeskMessage]) async -> BackendHootDeskStart {
        let memory = hooks.memory(), now = hooks.now()
        var parts: [String] = [], over = 0, ready = false
        var leftOut: [String] = []
        // Whole items are left out when the opening is too long (oldest board rows first, never the top rules); the text says which.
        if let opening = await BackendMCPCallBudget.within(5, { try? await DeckMemoryBrief.opening(memory, owner: .hoot, limit: Self.openingLimit) }) ?? nil {
            ready = true; over = opening.cardOverBy; leftOut = opening.leftOut
            if !opening.isEmpty { parts.append(opening.text) }
            cardSeen = try? await memory.assembledCard(.hoot).text
            topicsOnDesk = Set(((try? await memory.topics(.hoot, includeClosed: false)) ?? []).map(\.title))
        } else { hooks.log("memory was not ready when Hoot started; the desk has no card yet") }
        if ready, let projects = await Self.projectLines(memory) { parts.append(projects) }
        if fresh, let tail = Self.tail(recent, at: now) { parts.append(tail) }
        parts.append(Self.howTo)
        // The skills that ship with the app: Hoot follows them like any session does (and reports their steps).
        if let skills = Self.builtInSkills() { parts.append(skills) }
        briefedAt = now
        return .init(text: parts.joined(separator: "\n\n"), cardOverBy: over, memoryReady: ready, leftOut: leftOut)
    }

    static func builtInSkills(folder: URL? = BackendBuiltInSkills.folder()) -> String? {
        let names = BackendBuiltInSkills.names(in: folder)
        guard let folder, !names.isEmpty else { return nil }
        return "## Skills that ship with Terminal Deck\n" + names.joined(separator: ", ") + ". Each is " + folder.path + "/<name>/SKILL.md. "
            + "When a request fits one and the folder you work in has no skill of that name, read that SKILL.md and follow it, reporting each step with `" + JobFlowWords.toolWire + "`." + SkillCommandNames.promptLine
            + (names.contains("start-an-agent") ? " Before starting an agent, read start-an-agent and decide whether delegation is needed, which existing named agent fits and what result it should return." : "")
    }

    /// Each project's own line on what it is (the project guide's "What it is", kept in the project's card).
    static func projectLines(_ memory: any DeckMemoryStoring) async -> String? {
        var lines: [String] = []
        for info in (try? await memory.owners()) ?? [] {
            guard case .project(let id) = info.owner, let card = try? await memory.card(info.owner) else { continue }
            let about = DeckMemoryBrief.section(named: [DeckMemoryCard.projectAboutHeading.lowercased()], in: card.text).joined(separator: " ")
            guard !about.isEmpty else { continue }
            let name: String = info.name.isEmpty ? id : info.name
            let line: String = "- \(name) (\(id)): \(about.prefix(300))"
            lines.append(line)
        }
        return lines.isEmpty ? nil : "## What each project is\n" + lines.sorted().joined(separator: "\n")
    }

    /// The last messages, word for word, for a desk that starts clean. A size budget, not a count:
    /// as many recent messages as fit, always back to the person's last message, which is given in full.
    static func tail(_ recent: [BackendHootDeskMessage], at: Date, budget: Int = tailBudget) -> String? {
        guard let said = said(recent, budget: budget) else { return nil }
        let when = DateFormatter(); when.dateFormat = "d MMM yyyy, HH:mm"
        return "## The last messages, word for word\nThis desk was started clean on purpose at \(when.string(from: at)). Nothing before this point is in view any more; everything earlier is in the diary, word for word (`memory_search`; the lookup words in your topic notes help). Carry on from here. The person still sees the whole chat and did not see the desk change, so do not bring it up.\n\n" + said
    }
    /// As many recent messages as fit the budget, word for word, always back to the person's last message (given whole).
    public static func said(_ recent: [BackendHootDeskMessage], budget: Int = tailBudget) -> String? {
        let all = recent.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !all.isEmpty else { return nil }
        let lastPerson = all.lastIndex { $0.fromPerson } ?? all.count - 1
        var kept: [String] = [], used = 0
        for index in all.indices.reversed() {
            let required = index >= lastPerson, text = required ? shortened(all[index].text) : all[index].text
            guard required || (used + text.count <= budget && kept.count < tailMessages) else { break }
            kept.insert((all[index].label ?? (all[index].fromPerson ? "The person" : "You")) + ": " + text, at: 0); used += text.count
        }
        return kept.joined(separator: "\n\n")
    }
    /// A very long message keeps its start and its end; the diary has all of it.
    static func shortened(_ text: String) -> String {
        guard text.count > messageCap else { return text }
        let half = messageCap / 2
        return String(text.prefix(half)) + "\n[… \(text.count - messageCap) characters left out here; the diary has the full text (memory_search) …]\n" + String(text.suffix(half))
    }

    // MARK: A few lines with every message

    /// The hidden block for one message Hoot receives. Empty when there is nothing to say.
    public func lines(for text: String, context: NativeRPCValue = .object([])) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A CLI command ("/model") is passed on exactly as typed.
        guard !trimmed.hasPrefix("/") else { return "" }
        let memory = hooks.memory(), since = briefedAt, now = hooks.now(), seen = cardSeen, shown = topicsOnDesk
        let built: Lines? = await BackendMCPCallBudget.within(2) {
            let kinds = ((try? await memory.playbook(.hoot))?.rows.map(\.jobKind)) ?? []
            var moment = Self.moment(text: trimmed, context: context, jobKinds: kinds)
            // A playbook row with nothing in it says nothing: no line for it.
            if case .startingSession(let job) = moment {
                let row = try? await memory.playbookRow(.hoot, job: job ?? "")
                if row.map({ DeckMemoryBrief.playbookLine($0).isEmpty }) ?? true { moment = .plain }
            }
            // M1 fits these to the limit: fewer board changes first, then the moment's lines, never the top rules.
            guard var brief = try? await DeckMemoryBrief.messageLines(memory, owner: .hoot, since: since, moment: moment,
                                                                     limit: DeckMemoryBrief.Limit.messageLines) else { return Lines(text: "", card: nil) }
            // What else is stored on this, by title only, so Hoot knows there is something to read.
            if let index = await Self.index(memory, for: trimmed, onDesk: shown) {
                brief = .init(text: brief.text.isEmpty ? index : brief.text + "\n\n" + index, cardOverBy: brief.cardOverBy)
            }
            // The card was edited while this desk is open: the new lines go with this message, once.
            let card = try? await memory.assembledCard(.hoot).text
            if let card, let seen, card != seen {
                let edited = Self.cardEdit(old: seen, new: card)
                brief = .init(text: brief.text.isEmpty ? edited : brief.text + "\n\n" + edited, cardOverBy: brief.cardOverBy)
            }
            return Lines(text: brief.text, card: card)
        }
        guard let built else { hooks.log("memory took too long; this message went without its lines"); return "" }
        briefedAt = now
        if let card = built.card { cardSeen = card }
        let body = built.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The app's own marker, the same one sessions get, so nothing the app lays down is ever stored as the person's words.
        return body.isEmpty ? "" : DeckMemoryBrief.wrap(body)
    }
    private struct Lines: Sendable { var text: String; var card: String? }

    /// One short line: the titles of notes and topics that match this message. Titles only (an index), never the content.
    /// `onDesk`: the topics laid down when this desk started; the index names what is not already there.
    static func index(_ memory: any DeckMemoryStoring, for text: String, onDesk: Set<String> = []) async -> String? {
        let words = keywords(text)
        guard !words.isEmpty, let found = try? await memory.search(.init(words.joined(separator: " "), kinds: [.note, .topic], limit: 8)) else { return nil }
        // A match on one everyday word is noise: two of the message's own words, or its only one.
        let needed = min(2, words.count)
        let titles = found.hits.filter { hit in
            guard !hit.archived, !hit.title.isEmpty, !(hit.kind == .topic && onDesk.contains(hit.title)) else { return false }
            let haystack = (hit.title + " " + hit.snippet).lowercased()
            return words.filter { haystack.contains($0) }.count >= needed
        }.prefix(4).map { ($0.kind == .topic ? "topic " : "note ") + "\u{201C}" + String($0.title.prefix(60)) + "\u{201D}" }
        return titles.isEmpty ? nil : "Also in your memory on this (titles only; memory_search reads them): " + titles.joined(separator: ", ") + "."
    }
    static let everydayWords: Set<String> = ["what", "when", "where", "which", "while", "with", "without", "would", "could", "should", "about", "after", "again", "also",
        "been", "before", "being", "does", "doing", "done", "from", "have", "having", "here", "into", "just", "know", "last", "like", "make", "more", "much",
        "need", "next", "only", "over", "please", "really", "some", "still", "than", "thanks", "that", "their", "them", "then", "there", "these", "they", "thing",
        "things", "this", "those", "time", "today", "tomorrow", "want", "week", "well", "were", "will", "your", "yesterday", "find", "found", "tell", "show", "give"]
    /// The message's own words: four letters or more, not everyday ones, at most eight.
    static func keywords(_ text: String) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        where word.count >= 4 && !everydayWords.contains(word) && seen.insert(word).inserted && result.count < 8 { result.append(word) }
        return result
    }

    /// The lines of a card that are new since Hoot last got it.
    static func cardEdit(old: String, new: String) -> String {
        let before = Set(old.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var added: [String] = [], used = 0
        for raw in new.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !before.contains(line), used + line.count <= 800, added.count < 12 else { continue }
            added.append(line); used += line.count
        }
        if added.isEmpty { return "Your card was edited since this desk started (lines were removed). memory_card_read shows it as it is now." }
        return "Your card was edited since this desk started. New or changed lines:\n" + added.joined(separator: "\n")
    }

    /// The delivered message: exactly what was written, then the app's lines.
    public static func deliver(hidden: String, message: String, maximumBytes: Int = 262_144) -> String {
        guard !hidden.isEmpty else { return message }
        let combined = message + "\n\n" + hidden
        return combined.utf8.count <= maximumBytes ? combined : message
    }

    static let permissionWords = ["permission", "approve", "approval", "allow ", "allowed", "may i ", "may it ", "wants to run", "asks to", "asking to", "can it run", "bypass", "needs your ok"]
    static let workWords = ["session", "agent", "start ", "kick off", "spin up", "hand ", "delegate", "assign", "steer", "ask the ", "tell the ", "build", "fix", "implement", "review", "investigate", "research", "ship", "release", "deploy", "refactor", "test "]
    /// Which extra lines fit this message. Plain rules on the words, never an AI call.
    static func moment(text: String, context: NativeRPCValue, jobKinds: [String]) -> DeckMemoryMoment {
        let low = " " + text.lowercased() + " "
        let kind = (context["source"]["kind"].string ?? "").lowercased()
        if kind.contains("permission") || kind.contains("approval") || permissionWords.contains(where: low.contains) { return .permissionQuestion }
        let named = jobKinds.contains { job in
            let name = job.lowercased()
            return !name.isEmpty && !DeckMemoryPlaybookRow.fallbackKinds.contains(name) && low.contains(name)
        }
        if named || workWords.contains(where: low.contains) || !(context["mentions"].elements ?? []).isEmpty { return .startingSession(job: text) }
        return .plain
    }

    // MARK: Words

    /// The report every worker is asked for. Added to each brief sent through sessions.start.
    public static let reportForm = """
    ## Report back in this form
    1. Done or not done.
    2. The result, in three lines.
    3. Proof: the command and its output, the file, the screenshot or the link.
    4. What you need from me.
    """

    /// How Hoot's desk works: the part the app does and its card cannot know. The rules themselves (top
    /// rules, how to use memory, the report form) are in the orchestrator template, which is in the card above.
    public static let howTo = """
    ## How this desk works

    - **Your card, your open topics and the board are above.** They are rebuilt from the app's memory every time you start.
    - **Each message ends with a few lines from the app**, between `<\(DeckMemoryBrief.tag)>` and `</\(DeckMemoryBrief.tag)>`: your top rules, lines that fit the moment (the playbook row when work is about to be handed out, your permission rules on a permission question), what changed on the board since your last message, and the titles of notes and topics that match the message. The app wrote them, not the person. Use them; do not quote them back and do not answer them.
    - **The app never wipes your conversation.** It goes on as one conversation; when it grows long it is compacted, never cleared. Nothing is lost: the diary keeps every message word for word, and the person's chat window does not change.
    - **Keep one "where we are" note per open topic** (`memory_topic_update`), in this shape, because it is what you carry on from after a compaction or on a clean desk: the goal · where we are now · decisions and why · the person's corrections in their own words · open items and who is waiting · the next step, with the person's latest request quoted · lookup words for finding the detail in the diary. Replace the text when the state changes; do not append a log.
    - **Search before you say you do not know.** A name, project or decision you do not recognise: search memory first. Before investigating something again, search memory for the earlier result. A note is a pointer: when the detail matters, read the diary passage it came from, not only the note.

    ## Giving work to sessions and agents

    - **The playbook picks the set-up.** `sessions_start` fills in the AI, model, effort, permission and standing instructions from your playbook when you leave them out. Name the kind of job in `job`; without it the title is read for one, then the default row is used. To differ, pass `differ` with your own model, effort, permission or instructions and a `reason` saying why. Bypass can only come from the playbook, never from you.
    - **Address the seat, not the hire.** Work goes to a seat: a project and a role ("Shop · iOS", "Website · lead"). Whoever holds the seat today does it, and its memory stays with the seat when the agent is replaced. Do not write a brief to a named individual.
    - **You are the one asking, not the person.** In a session you start or steer, your words are yours: say what the person asked for and quote them when it matters, and never present your own instruction as the person's rule.
    - **The report form goes with every brief.** A brief sent through `sessions_start` gets it added for you: done or not · the result in three lines · the proof · what it needs. Report to the person in the same shape.
    - **Every AI-to-AI job has a visible chat.** For Hoot → lead, lead → worker or worker → worker, use `sessions_conversations` start with the saved agent, project folder, title and text brief. Keep follow-ups in that session while it is open. Read its turn to get the answer. An answer closes its AI and saves that job's history; new work starts a new session. Start from the brief, card, topics and notes, never by re-reading past conversations. List/read finds past chats when the person asks to inspect them. Never ask a worker to start a hidden CLI conversation.
    - **Task work happens in separate task conversations, never here.** Each task you work on (a task thread, a comment that names you, a delegation, a CRM task) runs in its own conversation with its own answers on the task's thread. When the person asks here about a task, read it before answering: its status, thread and agents with the task tools (tasks_get, tasks_local), and the "where we are" topic that task's conversation keeps in your memory (memory_search "Task <id>"). Never guess.
    - **Every result is in one of three states.** *Attempted*: the work was given out. *Reported*: the worker says it is done. *Verified*: you checked the proof yourself, at the source. Say which one it is every time, and never pass on a reported result as verified.

    \(BackendHootDesk.jobFlow)

    \(BackendHootDesk.answerShape)
    """

    /// Asad (12 Oct): the live job flow shows the rules applied with a green tick and each skill step. Nothing is guessed:
    /// only what is reported with `flow_applied` shows.
    public static let jobFlow = """
    ## Your job flow (the person watches it live)

    - **While you work, the person sees a live list of what you do.** Your tool calls show by themselves.
    - **When you apply one of your rules, say so with `\(JobFlowWords.toolWire)`** at that moment: `rule` is the note's id (n-…) or the rule's own words as written in your card or notes. It shows with a green tick and the rule's short title. A rule only counts as applied when you report it, so report each one you really follow, once per job.
    - **When you follow a skill, report each step as you reach it:** `\(JobFlowWords.toolWire)` with `skill` (its name), `step` (1, 2, 3…) and `stepTitle` (the step's few words).
    - It changes nothing and asks nobody. Agents you hand work to are told the same, so their rules and steps show under them in your flow.
    """

    /// Asad (12 Oct): "we struggle to understand which part is telling that things are done, which part is asking
    /// decisions … with small box around it … if you are doing ten things always give this in a proper table".
    public static let answerShape = """
    ## How your answers look

    The chat draws these marked parts as boxes, so the person sees at once what needs them. Each starts with a line `:::` + its kind and ends with a line `:::`:

    ```
    :::needs-you
    1. Ship the fix tonight, or wait for the review?
    2. Which account should the iOS agent use?
    :::

    :::done
    - The sign-in fix is in, and its test passes (verified).
    :::

    :::waiting
    - The iOS agent is building; about 5 minutes left.
    :::

    :::heads-up
    - The disk has 4 GB left.
    :::
    ```

    - **Every decision, question or approval you need from the person goes in one `needs-you` box, always as a numbered list,** so they can answer by number. Never bury a question in a paragraph.
    - **Finished work goes in a `done` box**; what waits on an agent, a build or anything outside goes in a `waiting` box; a risk goes in a `heads-up` box. Leave out a box that would be empty.
    - **Three or more items, or the status of several things, go in a proper Markdown table**, never one long paragraph.
    - Write each box exactly with its two `:::` lines, never as a quote or a bold label.
    - Everything else is plain, short text, as before. Do not put the whole answer in boxes.
    """
}
