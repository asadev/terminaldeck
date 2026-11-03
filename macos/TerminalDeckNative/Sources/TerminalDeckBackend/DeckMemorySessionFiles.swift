import Foundation
import TerminalDeckNativeCore

/// The SEAT a terminal session fills (MEMORY-SPEC 3a): memory belongs to the seat (project + role), never to
/// the hire, so a new hire in the same seat gets the same card, notes and topics from its first message.
/// L4 AGENTS decides which seat a session fills (`DeckMemorySessionServices.owner`). Three categories exist:
/// Orchestrator (Hoot, not a terminal session), Lead and Agent; `temporary` is only an Agent in a short-lived
/// seat and is wired exactly like one. Nothing here is configured per individual.
public struct DeckMemorySessionOwner: Sendable, Codable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable { case hoot, lead, agent, temporary, plain }
    public var kind: Kind
    /// The seat: the role id for an Agent seat, the project id for a Lead seat. Empty for a plain session.
    public var id: String
    /// The hire's name: a detail for history and for the greeting, never what memory is keyed by.
    public var name: String
    /// The project's folder name under `projects/` in the memory folder, when the session belongs to one.
    public var project: String?
    /// Card, notes and topics. Off for plain sessions (they still reach the diary and the board).
    public var memoryOn: Bool
    /// Spec 3b: which hand on the seat this session is (1, 2, 3…) when the app tracks hands; nil = not tracked.
    public var hand: Int?
    /// The job (the piece of work) this hand holds. "Where we are" topics belong to the job, not to the seat.
    public var job: String?
    public init(kind: Kind, id: String = "", name: String = "", project: String? = nil, memoryOn: Bool = false,
                hand: Int? = nil, job: String? = nil) {
        self.kind = kind; self.id = id; self.name = name; self.project = project; self.memoryOn = memoryOn
        self.hand = hand; self.job = job
    }
    /// Records written before 28 Oct 2026 may also hold `refreshAt` and `adopted` (the removed desk refresh and its
    /// protection mark): they are skipped when read, and never written again.
    private enum CodingKeys: String, CodingKey { case kind, id, name, project, memoryOn, hand, job }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(Kind.self, forKey: .kind), id: try values.decodeIfPresent(String.self, forKey: .id) ?? "",
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? "", project: try values.decodeIfPresent(String.self, forKey: .project),
                  memoryOn: try values.decodeIfPresent(Bool.self, forKey: .memoryOn) ?? false,
                  hand: try values.decodeIfPresent(Int.self, forKey: .hand), job: try values.decodeIfPresent(String.self, forKey: .job))
    }
    /// One line a hand is told about itself (empty when the seat has no hand numbers).
    public var handLine: String {
        guard let hand else { return job.map { " Your job in this session: \($0). Keep ONE \"where we are\" topic note for this job, titled with the job." } ?? "" }
        return " More than one session can fill this role at the same time; you are hand \(hand)." + (job.map { " Your job: \($0)." } ?? "")
            + " The role's notes are shared by every hand (write lessons and decisions back into them); your \"where we are\" topic note belongs to YOUR job, so keep one topic titled with the job and leave other hands' topics alone."
    }
    public static let plain = DeckMemorySessionOwner(kind: .plain)
    public var hasDesk: Bool { memoryOn && kind != .plain }
    /// "lead" or "agent": the category whose template applies.
    public var category: String { kind == .hoot ? "orchestrator" : kind == .lead ? "lead" : "agent" }
}

/// One finished turn of a terminal session: what M2 FLOW gets for diary capture, the helper and the board.
/// Sent for EVERY session, plain ones and chats the person types himself included.
public typealias DeckMemorySessionTurn = DeckMemoryFlowTurn

/// What the session side needs from the rest of Deck Memory. Every field has a file-based default
/// (`DeckMemorySessionFiles`), so sessions work from the plain folder alone; M1/M2/L4 replace fields with theirs.
public struct DeckMemorySessionServices: Sendable {
    public var memoryRoot: @Sendable () -> URL
    public var owner: @Sendable (BackendCreateSessionInput, _ provider: String) async -> DeckMemorySessionOwner
    /// Card + open topics + the board (+ the last messages word for word when `reason` is "compact").
    public var startContext: @Sendable (DeckMemorySessionOwner, BackendSessionMeta, _ reason: String, _ lastMessages: [(role: String, text: String)]) async -> String
    /// The few lines every message carries: the fixed top rules and what changed on the board.
    public var promptLines: @Sendable (DeckMemorySessionOwner, BackendSessionMeta) async -> String
    public var turnEnded: @Sendable (DeckMemorySessionTurn) async -> Void
    /// A message was just submitted in this session (the diary can take the prompt in at once).
    public var activity: @Sendable (_ sessionID: String) async -> Void
    /// PreCompact: make sure the owner's open topics are on disk.
    public var saveTopics: @Sendable (DeckMemorySessionOwner, BackendSessionMeta) async -> Void
    /// Spec 3b (L4 AGENTS binds it to BackendAGTHands): the session takes a hand on its seat; the answer is its
    /// hand number and job. Calling it again for the same session keeps the hand and updates the job.
    public var joinHand: @Sendable (_ sessionID: String, _ seat: DeckMemorySessionOwner, _ job: String?, _ taskID: String?) async -> (hand: Int, job: String?)?
    /// The session ended or no longer fills a seat.
    public var leaveHand: @Sendable (_ sessionID: String) async -> Void
    public var report: @Sendable (String) -> Void
    /// 28 Oct (Sessions, bug A): the session's own CLI started another conversation in the same process (/clear,
    /// /resume): the session owner writes it down so a restart or restore continues THAT one. Its own hook names
    /// it (the hook rides on the session's command line, so a nested CLI run inside the terminal never does).
    public var conversationChanged: @Sendable (_ sessionID: String, _ conversationID: String) async -> Void = { _, _ in }

    public static func files(memoryRoot: @escaping @Sendable () -> URL, report: @escaping @Sendable (String) -> Void = { _ in }) -> Self {
        .init(memoryRoot: memoryRoot,
              owner: { input, _ in DeckMemorySessionFiles.owner(input, root: memoryRoot()) },
              startContext: { owner, session, reason, last in await DeckMemorySessionFiles.startContext(owner, session: session, reason: reason, lastMessages: last, root: memoryRoot()) },
              promptLines: { owner, _ in DeckMemorySessionFiles.promptLines(owner, root: memoryRoot()) },
              // M2 FLOW's own entry point (returns at once, buffers until its engine starts).
              turnEnded: { turn in
                  var turn = turn
                  if turn.owner.project == nil { turn.owner.project = turn.projectID }
                  DeckMemoryFlowInbox.sessionTurnEnded(turn)
              },
              activity: { id in DeckMemoryFlowInbox.sessionActivity(sessionID: id) },
              saveTopics: { _, _ in }, joinHand: { _, _, _, _ in nil }, leaveHand: { _ in }, report: report)
    }
}

/// Reads the plain memory folder (MEMORY-SPEC section 1) directly. No database, no AI.
public enum DeckMemorySessionFiles {
    /// The memory folder, wherever M1 CORE keeps it ("Terminal Deck Memory"; follows a Move…). One name in every build.
    public static func defaultRoot() -> URL { DeckMemoryPaths.root(dataRoot: nil) }
    static func safe(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 120 && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }
    /// The seat's own folder: `projects/<project>/roles/<role>/` (or `roles/<role>/` outside any project) for an
    /// Agent seat, `projects/<project>/lead/` for a Lead seat.
    public static func folder(_ owner: DeckMemorySessionOwner, root: URL) -> URL? {
        switch owner.kind {
        case .agent, .temporary:
            guard safe(owner.id) else { return nil }
            if let project = owner.project, safe(project) {
                return root.appendingPathComponent("projects").appendingPathComponent(project).appendingPathComponent("roles").appendingPathComponent(owner.id, isDirectory: true)
            }
            return root.appendingPathComponent("roles").appendingPathComponent(owner.id, isDirectory: true)
        case .lead:
            let project = owner.project ?? owner.id
            guard safe(project) else { return nil }
            return root.appendingPathComponent("projects").appendingPathComponent(project).appendingPathComponent("lead", isDirectory: true)
        case .hoot: return root.appendingPathComponent("hoot", isDirectory: true)
        case .plain: return nil
        }
    }
    static func projectFolder(_ owner: DeckMemorySessionOwner, root: URL) -> URL? {
        guard let project = owner.project, safe(project) else { return nil }
        return root.appendingPathComponent("projects").appendingPathComponent(project, isDirectory: true)
    }
    static func text(_ file: URL, limit: Int) -> String? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 2 * 1024 * 1024, let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "\n… (cut here; the whole file is at \(file.path))" : text
    }
    /// Only when L4 AGENTS has not bound its seat resolver: without it nobody knows which seat a session
    /// fills, so every session is a plain one (diary and board still work).
    public static func owner(_ input: BackendCreateSessionInput, root: URL) -> DeckMemorySessionOwner { .plain }
    /// The category template's shared card text: `templates/lead/card.md` or `templates/agent/card.md`.
    static func template(_ owner: DeckMemorySessionOwner, root: URL) -> String? {
        text(root.appendingPathComponent("templates").appendingPathComponent(owner.category).appendingPathComponent("card.md"), limit: 3_000)
    }

    /// What a session is told at the top of a clean desk. Kept under the CLI's hook-output limit; the paths let
    /// the agent read the rest itself.
    public static func startContext(_ owner: DeckMemorySessionOwner, session: BackendSessionMeta, reason: String,
                                    lastMessages: [(role: String, text: String)], root: URL) async -> String {
        await DeckMemorySessionBinding.startContext(owner, session: session, reason: reason, lastMessages: lastMessages, root: root, filesOnly: true)
    }

    /// No writes, index rebuild or startup dependency. The board is read from its existing database, if present.
    static func opening(_ owner: DeckMemoryOwner, job: String?, limit: Int?, root: URL) -> DeckMemoryBriefText {
        let template = owner.category.map { DeckMemoryStore.readTemplate($0, root: root) }
        let own = DeckMemoryFiles.read(root.appendingPathComponent(owner.cardPath)) ?? ""
        let card = DeckMemoryAssembledCard(owner: owner, shared: template?.card ?? "", own: own, limit: template?.cardLimit ?? DeckMemoryCard.defaultLimit)
        let project = owner.isSeat ? owner.projectID.flatMap { DeckMemoryFiles.read(root.appendingPathComponent(DeckMemoryOwner.project($0).cardPath)) } ?? "" : ""
        var topics: [DeckMemoryTopic] = []
        if template?.has(.topics) ?? true {
            for path in DeckMemoryFiles.markdown(under: root.appendingPathComponent(owner.topicsFolder), depth: 1) {
                let relative = owner.topicsFolder + "/" + path
                guard let text = DeckMemoryFiles.read(root.appendingPathComponent(relative)), let info = DeckMemoryFiles.info(root.appendingPathComponent(relative)) else { continue }
                let file = DeckMemoryFile(text: text), parts = file.headingAndRest
                guard !["closed", "done", "rewound"].contains((file.value("status") ?? "open").lowercased()) else { continue }
                let ownJob = file.value("job")
                if let job, !job.isEmpty, let ownJob, ownJob != job { continue }
                let date = DeckMemoryFiles.date(file.value("date")) ?? Date(timeIntervalSince1970: info.mtime)
                let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                topics.append(.init(id: id, owner: owner, title: file.value("title") ?? parts.title ?? id,
                    body: parts.title == nil ? file.body.trimmingCharacters(in: .whitespacesAndNewlines) : parts.rest, open: true, path: relative,
                    labels: .init(owner: owner, project: file.value("project") ?? owner.projectID, date: date, type: "topic", job: ownJob), updatedAt: date))
            }
            topics.sort { a, b in
                if (a.job == nil) != (b.job == nil) { return a.job != nil }
                return a.updatedAt > b.updatedAt
            }
        }
        var rows: [DeckMemoryBoardRow] = []
        if template?.has(.board) ?? true, let db = try? DeckMemoryDatabase(path: root.appendingPathComponent("memory.db").path, readOnly: true) {
            defer { db.close() }
            let scope = DeckMemoryStore.scopeClause(owner)
            let filter = scope.map { " AND " + $0.sql } ?? ""
            rows = ((try? db.rows("SELECT \(DeckMemoryStore.boardColumns) FROM board WHERE archived IS NULL" + filter + " ORDER BY updated DESC, id LIMIT ?",
                                 (scope?.args ?? []) + [.int(Int64(DeckMemoryBrief.boardRowsInOpening))])) ?? []).map { DeckMemoryStore.boardRow($0, now: Date()) }
        }
        return DeckMemoryBrief.opening(card: card, template: template, projectCard: project, topics: topics, rows: rows, root: root, owner: owner, limit: limit)
    }
    static let reportForm = "## Report form (use it when you report back to your lead or Hoot)\ndone or not · the result in three lines · proof · what you need. Long output stays in this session."

    /// The fixed top rules: the bullet lines under the card's first "rules" heading (at most six).
    public static func promptLines(_ owner: DeckMemorySessionOwner, root: URL) -> String {
        guard owner.hasDesk, let folder = folder(owner, root: root) else { return "" }
        let card = [template(owner, root: root), text(folder.appendingPathComponent("card.md"), limit: 20_000)].compactMap { $0 }.joined(separator: "\n")
        guard !card.isEmpty else { return "" }
        var rules: [String] = [], inRules = false
        for line in card.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { if inRules, !rules.isEmpty { break }; inRules = trimmed.lowercased().contains("rule"); continue }
            if inRules, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil { rules.append(trimmed) }
            if rules.count == 6 { break }
        }
        guard !rules.isEmpty else { return "" }
        return "Standing rules from your card (Terminal Deck memory):\n" + rules.joined(separator: "\n")
    }
}
