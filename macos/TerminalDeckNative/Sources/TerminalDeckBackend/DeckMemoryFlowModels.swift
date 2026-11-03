import Foundation
import TerminalDeckNativeCore

// Deck Memory, the flow that fills it (lane M2 FLOW, design-2026-10-10/MEMORY-SPEC.md).
// The app writes the diary and the board itself; an AI only ever writes short notes,
// and the app, never the AI, decides who and what project they belong to.
// Storage is lane M1 CORE's (`DeckMemoryStoring`); this file holds what the flow adds.

/// Who a session belongs to, as the session host knows it (L8 HOST fills it).
public typealias DeckMemoryFlowOwner = DeckMemorySessionOwner

public extension DeckMemorySessionOwner {
    /// Compatibility for flow signals and persisted jobs; the session and flow now carry the same seat.
    init(kind: String, id: String, name: String, project: String, memoryOn: Bool = true) {
        self.init(kind: Kind(rawValue: kind) ?? .plain, id: id, name: name, project: project.isEmpty ? nil : project, memoryOn: memoryOn)
    }
    static let hoot = DeckMemorySessionOwner(kind: .hoot, id: "hoot", name: "Hoot", memoryOn: true)
    static func plain(project: String) -> DeckMemorySessionOwner { .init(kind: "plain", id: "", name: "", project: project) }
    var memoryOwner: DeckMemoryOwner {
        let project = project ?? ""
        let shared: DeckMemoryOwner = project.isEmpty ? .hoot : .project(project)
        switch kind {
        case .hoot: return .hoot
        case .lead: return (project.isEmpty ? id : project).isEmpty ? .hoot : .lead(project.isEmpty ? id : project)
        case .agent, .temporary: return id.isEmpty ? shared : .role(project: project.isEmpty ? nil : project, role: id)
        case .plain: return shared
        }
    }
    func stamp(session: String, provider: String, hand: Int? = nil, job: String? = nil) -> DeckMemoryStamp {
        DeckMemoryStamp(owner: memoryOwner, project: project.flatMap { $0.isEmpty ? nil : $0 }, session: session,
                        agent: kind == .hoot ? "hoot" : (name.isEmpty ? provider : name), hand: hand ?? self.hand, job: job ?? self.job)
    }
}

/// "An agent finished its answer and stopped." L8 HOST sends this for terminal sessions;
/// Hoot's is produced by the flow from Hoot's own event stream.
public struct DeckMemoryFlowTurn: Sendable, Equatable, Codable {
    public var sessionID: String
    public var provider: String
    public var owner: DeckMemoryFlowOwner
    public var cwd: String
    public var projectID: String?
    public var conversationID: String?
    public var transcriptPath: String?
    /// What the person asked, when the signal carries it.
    public var prompt: String?
    /// The agent's final words, when the signal carries them.
    public var lastAnswer: String?
    public var title: String
    public var at: Double
    /// hook | status | hoot | manual
    public var source: String
    public init(sessionID: String, provider: String, owner: DeckMemoryFlowOwner, cwd: String = "", projectID: String? = nil,
                conversationID: String? = nil, transcriptPath: String? = nil, prompt: String? = nil, lastAnswer: String? = nil,
                title: String = "", at: Double = Date().timeIntervalSince1970 * 1000, source: String = "hook") {
        self.sessionID = sessionID; self.provider = provider; self.owner = owner; self.cwd = cwd; self.projectID = projectID
        self.conversationID = conversationID; self.transcriptPath = transcriptPath; self.prompt = prompt
        self.lastAnswer = lastAnswer; self.title = title; self.at = at; self.source = source
    }
}

/// The diary session id of Hoot's own chat. Fixed, so the chat stays one chat across a restart
/// and across a switch between Claude, Codex and Gemini.
public enum DeckMemoryFlowNames {
    public static let hootSession = "hoot"
    public static let hootBoardRow = DeckMemoryBoardRow.rowID(.chat, "hoot")
    /// Set in the environment of every helper and tidy-up run, so nothing ever captures them as a conversation.
    public static let helperRunVariable = "TERMINALDECK_MEMORY_HELPER"
    /// `context.source.kind` (and the diary row's `meta["source"]`) of a builder's test message sent through the
    /// dev copy's test door. Never the person's words; the helper and the tidy-up skip its whole turn.
    public static let testSource = "dev-test"
    /// `context.source.kind` of a message the app itself put into Hoot's chat (the task engine, a routine, a
    /// button such as "Context handoff"). Shown in the chat, but never the person's own words.
    public static let appSources: Set<String> = ["task", "routine", "automation", "app", "button", "handoff"]
    /// Turns the helper and the tidy-up leave alone altogether: a builder's test, and a handoff Hoot was asked to
    /// write (a handoff document is made FROM memory; it is derived material, never a source of new facts).
    public static let skippedSources: Set<String> = [testSource, "handoff"]
    /// A diary row's `meta` key saying whose task or words the APP was carrying when it typed the row into a
    /// session: "person", "orchestrator" or "agent:<id>". The row's author stays "app": the app typed it.
    public static let givenByKey = "given_by"
    public static func sessionRow(_ id: String) -> String { DeckMemoryBoardRow.rowID(.session, id) }
}

/// Settings the flow keeps in memory.db (plain text, for the whole app). The helper's AI, model and
/// checklist are NOT here: they belong to the category template (one per category, spec 3a).
public enum DeckMemoryFlowKeys {
    /// "0" switches the helper off (the diary and the board keep filling).
    public static let helperOn = "helper.on"
    /// Seconds of quiet after a turn end before the helper reads it (default 20).
    public static let helperPause = "helper.pause-seconds"
    /// Helper jobs at once: "1" or "2" (default 1).
    public static let helperParallel = "helper.parallel"
    /// "0" switches the nightly tidy-up off.
    public static let tidyOn = "tidy.on"
    /// Local hour (0...23) after which the tidy-up may run (default 3).
    public static let tidyHour = "tidy.hour"
    /// The day ("2026-10-11") the tidy-up last finished, per owner.
    public static let tidyLastDay = "tidy.last-day"
}

/// The part of the memory store the flow uses, in M1's own types. `DeckMemoryFlowStoreAdapter`
/// forwards to the real store; the checks use a small in-memory one.
public protocol DeckMemoryFlowStore: Sendable {
    func appendDiary(_ drafts: [DeckMemoryDiaryDraft]) async throws -> [DeckMemoryDiaryEntry]
    func diary(_ query: DeckMemoryDiaryQuery) async throws -> [DeckMemoryDiaryEntry]
    func updateBoard(_ update: DeckMemoryBoardUpdate) async throws
    func archiveBoardRow(id: String) async throws
    /// The board changes of one moment together (the real store writes them in one transaction).
    func writeBoard(_ updates: [DeckMemoryBoardUpdate], archive: [String]) async throws
    func addNote(_ draft: DeckMemoryNoteDraft) async throws -> DeckMemoryNote
    func note(id: String) async throws -> DeckMemoryNote?
    func notes(_ query: DeckMemoryNoteQuery) async throws -> [DeckMemoryNote]
    /// The current notes of this seat most like `text` (words and meaning), best first. No AI.
    func similarNotes(owner: DeckMemoryOwner, text: String, limit: Int) async throws -> [DeckMemoryNote]
    func archiveNote(id: String, reason: String, replacedBy: String?) async throws
    /// The seat's card as delivered: the category template plus the seat's own additions.
    func assembledCard(_ owner: DeckMemoryOwner) async throws -> DeckMemoryAssembledCard
    /// The category's one template: checklist, helper AI and model, which parts the category gets.
    func template(_ category: DeckMemoryCategory) async throws -> DeckMemoryTemplate
    func saveTemplate(_ template: DeckMemoryTemplate) async throws
    /// Every seat with memory, occupied or vacant.
    func owners() async throws -> [DeckMemoryOwnerInfo]
    /// A closed short-lived helper seat's notes and topics go back to its parent seat.
    func foldBack(_ helper: DeckMemoryOwner) async throws
    func addQuestion(owner: DeckMemoryOwner, text: String, context: String, refs: [String]) async throws
    func questions(owner: DeckMemoryOwner) async throws -> [DeckMemoryQuestion]
    func value(_ key: String, owner: DeckMemoryOwner?) async throws -> String?
    func setValue(_ value: String?, key: String, owner: DeckMemoryOwner?) async throws
    /// The job's own "where we are" topics plus the seat-wide ones.
    func topics(_ owner: DeckMemoryOwner, job: String?) async throws -> [DeckMemoryTopic]
    func updateTopic(_ owner: DeckMemoryOwner, title: String, body: String, stamp: DeckMemoryStamp?) async throws
    func backup() async throws
    func reindex() async throws
}

public extension DeckMemoryFlowStore {
    /// One by one, for a store without its own batch (the checks' small in-memory store).
    func writeBoard(_ updates: [DeckMemoryBoardUpdate], archive: [String]) async throws {
        var refused: Error?
        for update in updates { do { try await updateBoard(update) } catch { refused = refused ?? error } }
        for id in archive { try? await archiveBoardRow(id: id) }
        if let refused { throw refused }
    }
}

public struct DeckMemoryFlowStoreAdapter: DeckMemoryFlowStore {
    private let base: any DeckMemoryStoring
    public init(_ base: any DeckMemoryStoring) { self.base = base }
    public func appendDiary(_ drafts: [DeckMemoryDiaryDraft]) async throws -> [DeckMemoryDiaryEntry] { try await base.appendDiary(drafts) }
    public func diary(_ query: DeckMemoryDiaryQuery) async throws -> [DeckMemoryDiaryEntry] { try await base.diary(query) }
    public func updateBoard(_ update: DeckMemoryBoardUpdate) async throws { _ = try await base.updateBoard(update) }
    public func archiveBoardRow(id: String) async throws { _ = try await base.archiveBoardRow(id: id) }
    public func writeBoard(_ updates: [DeckMemoryBoardUpdate], archive: [String]) async throws { try await base.writeBoard(updates, archive: archive) }
    public func addNote(_ draft: DeckMemoryNoteDraft) async throws -> DeckMemoryNote { try await base.addNote(draft) }
    public func note(id: String) async throws -> DeckMemoryNote? { try await base.note(id: id) }
    public func notes(_ query: DeckMemoryNoteQuery) async throws -> [DeckMemoryNote] { try await base.notes(query) }
    public func similarNotes(owner: DeckMemoryOwner, text: String, limit: Int) async throws -> [DeckMemoryNote] {
        let wanted = String(text.prefix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, limit > 0 else { return [] }
        let hits = try await base.search(.init(wanted, owner: owner, kinds: [.note], limit: limit)).hits
        var found: [DeckMemoryNote] = []
        for hit in hits where hit.kind == .note && !hit.archived {
            if let note = try await base.note(id: hit.ref), !note.isArchived, !found.contains(where: { $0.id == note.id }) { found.append(note) }
        }
        return found
    }
    public func archiveNote(id: String, reason: String, replacedBy: String?) async throws {
        _ = try await base.archiveNote(id: id, reason: reason, replacedBy: replacedBy)
    }
    public func assembledCard(_ owner: DeckMemoryOwner) async throws -> DeckMemoryAssembledCard { try await base.assembledCard(owner) }
    public func template(_ category: DeckMemoryCategory) async throws -> DeckMemoryTemplate { try await base.template(category) }
    public func saveTemplate(_ template: DeckMemoryTemplate) async throws { _ = try await base.saveTemplate(template) }
    public func owners() async throws -> [DeckMemoryOwnerInfo] { try await base.owners() }
    public func foldBack(_ helper: DeckMemoryOwner) async throws { _ = try await base.foldBack(helper, into: nil) }
    public func addQuestion(owner: DeckMemoryOwner, text: String, context: String, refs: [String]) async throws {
        _ = try await base.addQuestion(owner: owner, text: text, context: context, refs: refs)
    }
    public func questions(owner: DeckMemoryOwner) async throws -> [DeckMemoryQuestion] { try await base.questions(owner: owner, openOnly: false) }
    public func value(_ key: String, owner: DeckMemoryOwner?) async throws -> String? { try await base.value(key, owner: owner) }
    public func setValue(_ value: String?, key: String, owner: DeckMemoryOwner?) async throws { try await base.setValue(value, key: key, owner: owner) }
    public func topics(_ owner: DeckMemoryOwner, job: String?) async throws -> [DeckMemoryTopic] { try await base.topics(owner, job: job, includeClosed: false) }
    public func updateTopic(_ owner: DeckMemoryOwner, title: String, body: String, stamp: DeckMemoryStamp?) async throws {
        _ = try await base.updateTopic(owner, title: title, body: body, stamp: stamp)
    }
    public func backup() async throws { _ = try await base.backup() }
    public func reindex() async throws { _ = try await base.reindex() }
}

/// One piece of work for the helper. Kept on disk until it is done, so a restart loses nothing.
public struct DeckMemoryFlowJob: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case turn, tidy }
    /// "turn:<session>" or "tidy:<owner key>:<day>": one job per session, one per owner and day.
    public var id: String
    public var kind: Kind
    /// The diary session (turn) or the owner key (tidy).
    public var subject: String
    public var title: String
    /// For a tidy-up: the day it covers ("2026-10-11").
    public var day: String?
    /// Milliseconds since 1970. nil = held until the session's next turn end.
    public var dueAt: Double?
    public var createdAt: Double
    public var attempts: Int
    public var lastError: String?
    public init(id: String, kind: Kind, subject: String, title: String = "", day: String? = nil, dueAt: Double?, createdAt: Double,
                attempts: Int = 0, lastError: String? = nil) {
        self.id = id; self.kind = kind; self.subject = subject; self.title = title; self.day = day; self.dueAt = dueAt
        self.createdAt = createdAt; self.attempts = attempts; self.lastError = lastError
    }
    public static func turnID(_ session: String) -> String { "turn:" + session }
    public static func tidyID(_ ownerKey: String, day: String) -> String { "tidy:" + ownerKey + ":" + day }
}

/// One finished run, for "last runs" in the profile.
public struct DeckMemoryFlowRun: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var kind: DeckMemoryFlowJob.Kind
    public var subject: String
    public var title: String
    public var at: Double
    public var ok: Bool
    /// One plain sentence: what it wrote, or why it failed.
    public var summary: String
    public var ai: String
    public var model: String
    public var milliseconds: Double
    /// What the run used, when the AI app reports it. nil = no AI was asked, or it did not say.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(id: String = UUID().uuidString, kind: DeckMemoryFlowJob.Kind, subject: String, title: String, at: Double, ok: Bool,
                summary: String, ai: String, model: String, milliseconds: Double, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.id = id; self.kind = kind; self.subject = subject; self.title = title; self.at = at; self.ok = ok
        self.summary = summary; self.ai = ai; self.model = model; self.milliseconds = milliseconds
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

/// What the profile shows about the flow (L5 PROFILE reads it through `DeckMemoryFlow.status()`).
public struct DeckMemoryFlowStatus: Sendable, Equatable, Codable {
    public var running: Bool
    public var helperOn: Bool
    /// "claude", "codex" or "gemini": the AI the helper runs on now.
    public var helperAI: String
    /// "" = that AI's own default model.
    public var helperModel: String
    public var pauseSeconds: Int
    public var parallel: Int
    public var waiting: [DeckMemoryFlowJob]
    public var runningJobs: [DeckMemoryFlowJob]
    public var lastRuns: [DeckMemoryFlowRun]
    public var tidyOn: Bool
    public var tidyHour: Int
    public var tidyLastDay: String?
    public var tidyRunning: Bool
    /// A plain sentence when something needs the person (not signed in, no AI app found).
    public var problem: String?
    public init(running: Bool = false, helperOn: Bool = true, helperAI: String = "claude", helperModel: String = "", pauseSeconds: Int = 20,
                parallel: Int = 1, waiting: [DeckMemoryFlowJob] = [], runningJobs: [DeckMemoryFlowJob] = [], lastRuns: [DeckMemoryFlowRun] = [],
                tidyOn: Bool = true, tidyHour: Int = 3, tidyLastDay: String? = nil, tidyRunning: Bool = false, problem: String? = nil) {
        self.running = running; self.helperOn = helperOn; self.helperAI = helperAI; self.helperModel = helperModel
        self.pauseSeconds = pauseSeconds; self.parallel = parallel; self.waiting = waiting; self.runningJobs = runningJobs
        self.lastRuns = lastRuns; self.tidyOn = tidyOn; self.tidyHour = tidyHour; self.tidyLastDay = tidyLastDay
        self.tidyRunning = tidyRunning; self.problem = problem
    }
}

public extension Notification.Name {
    /// Posted on the main thread whenever the flow's status changes (a job queued, started, finished).
    static let deckMemoryFlowChanged = Notification.Name("dev.terminaldeck.deck-memory.flow-changed")
}
