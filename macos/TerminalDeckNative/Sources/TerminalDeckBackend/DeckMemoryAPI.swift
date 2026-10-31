import Foundation
import TerminalDeckNativeCore

// Deck Memory: the API every lane calls (design-2026-10-10/MEMORY-API.md).
// Get the store with `await DeckMemory.ready()` (waits for the app to open it) or `DeckMemory.store`
// (right now; an "unavailable" store until the app has opened the real one).

/// The storage core of Deck Memory: one visible folder of Markdown files plus `memory.db`.
/// Rules it keeps: nothing is deleted, only archived; a newer note supersedes an older one and
/// keeps the link; every row carries app-stamped labels; a card over its size cap is reported,
/// never cut; a board result is attempted / reported / verified.
public protocol DeckMemoryStoring: Sendable {
    // MARK: Folder
    /// Where the memory folder is now, where it would be by default, and where it was before.
    func location() async -> DeckMemoryLocation
    /// "Move…": copies the whole folder to `newRoot` (which must not exist or be empty), reads every file back,
    /// switches to it, and leaves the old folder in place as an archive. Throws without switching if a check fails.
    func move(to newRoot: URL) async throws -> DeckMemoryMoveReport
    /// Reads every Markdown file again and brings the database in line with the disk (also runs by itself
    /// when a file is edited outside the app).
    @discardableResult func reindex() async throws -> DeckMemoryReindexReport
    /// A copy of memory.db inside `archive/backups/`. No AI.
    @discardableResult func backup() async throws -> URL
    /// Writes START-HERE.md and the CLAUDE.md / AGENTS.md / GEMINI.md pointers if they are missing or out of date.
    func writeStartHere() async throws

    // MARK: Seats (memory belongs to the seat, never to the hire)
    /// Every seat that has a folder (the orchestrator, lead seats, role seats) and every project's shared space.
    /// A seat nobody sits in is still listed, with what it remembers.
    func owners() async throws -> [DeckMemoryOwnerInfo]
    /// Creates the seat's folder and its own (empty) card if they are missing. `name` is the SEAT's title
    /// (the role's title, never the hire's name); it is kept and never overwritten by a later call.
    /// Hiring into an existing seat needs no call at all: the memory is already there.
    /// `parent`: for a short-lived helper seat, the seat it works under (kept; shown as `DeckMemoryOwnerInfo.parent`).
    @discardableResult func ensureOwner(_ owner: DeckMemoryOwner, name: String?, parent: DeckMemoryOwner?) async throws -> DeckMemoryOwnerInfo
    /// A short-lived helper seat closes: its notes and topics move into the parent seat (each note keeps its id and its
    /// history and gets a `folded_from` label; topics stay with their jobs), its own card goes to the archive, and its
    /// empty folder is removed. Its diary and board rows stay stamped with the helper seat, as history.
    /// `parent` nil = the parent recorded when the helper seat was made.
    @discardableResult func foldBack(_ helper: DeckMemoryOwner, into parent: DeckMemoryOwner?) async throws -> DeckMemoryFoldReport

    // MARK: Templates (one per category: orchestrator, lead, agent)
    /// The category's template: shared card text, helper checklist, which parts it gets, helper AI/model, card cap.
    func template(_ category: DeckMemoryCategory) async throws -> DeckMemoryTemplate
    /// Saves the template. It applies to every member of the category at once and to every future hire.
    /// Earlier versions are kept in `archive/versions/`.
    @discardableResult func saveTemplate(_ template: DeckMemoryTemplate) async throws -> DeckMemoryTemplate

    // MARK: Card
    /// The seat's OWN additions (`<seat>/card.md`). `overBy` already counts the template in front of it.
    func card(_ owner: DeckMemoryOwner) async throws -> DeckMemoryCard
    /// What the seat is actually given: the category template + the seat's own additions, with the size check.
    func assembledCard(_ owner: DeckMemoryOwner) async throws -> DeckMemoryAssembledCard
    /// Saves the seat's own text, whole. Never cuts: a card over the cap is saved and comes back with `overBy > 0`.
    /// The earlier version is kept in `archive/versions/`.
    @discardableResult func saveCard(_ owner: DeckMemoryOwner, text: String) async throws -> DeckMemoryCard
    /// The cap for the assembled card: the category template's `cardLimit`.
    func cardLimit(_ owner: DeckMemoryOwner) async throws -> Int
    /// Changes the cap in the owner's CATEGORY template (so for every seat in it); for a project's shared card, that project's own cap.
    func setCardLimit(_ limit: Int, for owner: DeckMemoryOwner) async throws

    // MARK: Notes
    /// Writes the note as a Markdown file with its labels on top. With `supersedes`, the older note is archived
    /// (reason "superseded"), both notes point at each other, and the new one links to it.
    @discardableResult func addNote(_ draft: DeckMemoryNoteDraft) async throws -> DeckMemoryNote
    /// The person edits a note in place. The earlier text is kept in `archive/versions/`.
    @discardableResult func updateNote(id: String, title: String?, body: String?, type: DeckMemoryNoteType?) async throws -> DeckMemoryNote
    /// Moves the note into `archive/`. `replacedBy`: the id of the note that replaced it, when one did.
    @discardableResult func archiveNote(id: String, reason: String, replacedBy: String?) async throws -> DeckMemoryNote
    /// Brings an archived note back to where it was.
    @discardableResult func restoreNote(id: String) async throws -> DeckMemoryNote
    /// Sets the note's very short title (3 to 6 words) and who made it; nothing else about the note changes.
    @discardableResult func setShortTitle(noteID: String, short: String, by: DeckMemoryShortTitle.Maker) async throws -> DeckMemoryNote
    func note(id: String) async throws -> DeckMemoryNote?
    /// Newest first.
    func notes(_ query: DeckMemoryNoteQuery) async throws -> [DeckMemoryNote]
    /// What this note replaced, and what that replaced, newest first (the note itself is not included).
    func history(ofNote id: String) async throws -> [DeckMemoryNote]

    // MARK: Diary
    /// Word for word, stamped with the app's clock. A draft whose `externalID` is already stored is not stored again
    /// (the stored row comes back).
    @discardableResult func appendDiary(_ draft: DeckMemoryDiaryDraft) async throws -> DeckMemoryDiaryEntry
    /// The same, for many at once (one transaction). Returns the rows in the same order.
    @discardableResult func appendDiary(_ drafts: [DeckMemoryDiaryDraft]) async throws -> [DeckMemoryDiaryEntry]
    func diary(_ query: DeckMemoryDiaryQuery) async throws -> [DeckMemoryDiaryEntry]
    /// "Jump to the moment": the row, and the rows around it in the same conversation (or session), in reading order.
    func diary(around id: Int64, before: Int, after: Int) async throws -> [DeckMemoryDiaryEntry]
    /// The newest row id (0 when the diary is empty).
    func diaryHead(session: String?) async throws -> Int64

    // MARK: Rewind (the conversation goes back to a chosen message; what came after is set aside, never deleted)
    /// Marks every live diary row of this seat's conversation that comes after row `after` as rewound. Those rows
    /// stay in the diary as history but leave the live conversation (the chat, the helper's reading, a desk rebuild).
    /// Notes whose diary rows ALL lie in the rewound part are archived with the reason "rewound"; a note that also
    /// rests on earlier rows stays. A topic first written in the rewound part is set aside; a topic that was only
    /// updated there gets the text it had before. Everything is kept and `undoRewind` puts it back.
    @discardableResult func markRewound(owner: DeckMemoryOwner, conversation: String, after: Int64) async throws -> DeckMemoryRewind
    /// Undoes one rewind: its rows are live again, its notes are restored, its topics get their rewound text back.
    /// Throws `conflict` when the conversation has gone on since (new messages after the rewind), or when a later
    /// rewind of the same conversation has not been undone first.
    @discardableResult func undoRewind(id: Int64) async throws -> DeckMemoryRewind
    /// Rewinds made so far, newest first. `conversation` nil = all of that seat's.
    func rewinds(owner: DeckMemoryOwner?, conversation: String?) async throws -> [DeckMemoryRewind]

    // MARK: Board
    /// Creates or changes one row from an app event. Throws `proofRequired` when `state` is verified without proof.
    @discardableResult func updateBoard(_ update: DeckMemoryBoardUpdate) async throws -> DeckMemoryBoardRow
    /// Most recently changed first.
    func board(_ query: DeckMemoryBoardQuery) async throws -> [DeckMemoryBoardRow]
    /// What changed on the board after `since`, oldest first ("what changed since the last message").
    func boardChanges(since: Date, owner: DeckMemoryOwner?) async throws -> [DeckMemoryBoardChange]
    /// A finished session or task leaves the board, never the database.
    @discardableResult func archiveBoardRow(id: String) async throws -> DeckMemoryBoardRow

    // MARK: Topics ("where we are": keyed to the JOB, so several hands on one seat keep one topic each)
    /// `job` nil: every topic of the seat. `job` set: that job's topic plus the seat's topics that belong to no job.
    func topics(_ owner: DeckMemoryOwner, job: String?, includeClosed: Bool) async throws -> [DeckMemoryTopic]
    func topic(_ owner: DeckMemoryOwner, id: String) async throws -> DeckMemoryTopic?
    /// Creates the topic, or replaces its text (the earlier text is kept in `archive/versions/`). With `stamp.job` set the
    /// topic is keyed to that job (id = a slug of the job), so another hand's topic is never overwritten; without a job the id is a slug of the title.
    @discardableResult func updateTopic(_ owner: DeckMemoryOwner, title: String, body: String, stamp: DeckMemoryStamp?) async throws -> DeckMemoryTopic
    /// Closed topics stay on disk and are no longer handed to a clean desk.
    @discardableResult func setTopic(_ owner: DeckMemoryOwner, id: String, open: Bool) async throws -> DeckMemoryTopic

    // MARK: Handoffs (a document kept with a topic, so another AI or person can pick the work up cold)
    /// Writes a new handoff document: `<seat>/topics/<topic>/handoffs/<date-time>.md`, or `<seat>/handoffs/…` when it
    /// covers the whole conversation. Every save is a new file. Posts a `.topics` change whose `ref` is "handoff:<id>".
    @discardableResult func saveHandoff(_ draft: DeckMemoryHandoffDraft) async throws -> DeckMemoryHandoff
    /// The person edited it and keeps the result: the text is replaced, the earlier text goes to `archive/versions/`.
    @discardableResult func updateHandoff(id: String, title: String?, markdown: String?) async throws -> DeckMemoryHandoff
    func handoff(id: String) async throws -> DeckMemoryHandoff?
    /// One seat's handoffs for one topic, newest first. `topic` nil = the ones written for the whole conversation.
    func handoffs(_ owner: DeckMemoryOwner, topic: String?, includeArchived: Bool) async throws -> [DeckMemoryHandoff]
    /// Every handoff of the seat, whatever the topic, newest first.
    func allHandoffs(_ owner: DeckMemoryOwner, includeArchived: Bool) async throws -> [DeckMemoryHandoff]
    /// Never deleted: moved under `archive/` at the same path. `restoreHandoff` brings it back.
    @discardableResult func archiveHandoff(id: String, reason: String) async throws -> DeckMemoryHandoff
    @discardableResult func restoreHandoff(id: String) async throws -> DeckMemoryHandoff

    // MARK: Playbook (Hoot and leads)
    func playbook(_ owner: DeckMemoryOwner) async throws -> DeckMemoryPlaybook
    @discardableResult func savePlaybook(_ owner: DeckMemoryOwner, rows: [DeckMemoryPlaybookRow], preface: String?) async throws -> DeckMemoryPlaybook
    /// The row to use for a job. A lead with no matching row falls back to Hoot's playbook.
    func playbookRow(_ owner: DeckMemoryOwner, job: String) async throws -> DeckMemoryPlaybookRow?

    // MARK: Search
    func search(_ query: DeckMemorySearchQuery) async throws -> DeckMemorySearchResult

    // MARK: Questions for you
    @discardableResult func addQuestion(owner: DeckMemoryOwner, text: String, context: String, refs: [String]) async throws -> DeckMemoryQuestion
    func questions(owner: DeckMemoryOwner?, openOnly: Bool) async throws -> [DeckMemoryQuestion]
    @discardableResult func answerQuestion(id: Int64, answer: String) async throws -> DeckMemoryQuestion
    /// The person waves a question away. It moves to the Dismissed list and `addQuestion` never raises the same
    /// question for that seat again (it hands back the dismissed one instead of making a new one).
    @discardableResult func dismissQuestion(id: Int64) async throws -> DeckMemoryQuestion
    /// "Ask me again after all": takes a question off the Dismissed list and makes it open.
    @discardableResult func reopenQuestion(id: Int64) async throws -> DeckMemoryQuestion

    // MARK: Small settings and extra files
    /// Plain text values kept in memory.db (`DeckMemoryKeys`). `owner` nil = for the whole app.
    func value(_ key: String, owner: DeckMemoryOwner?) async throws -> String?
    func setValue(_ value: String?, key: String, owner: DeckMemoryOwner?) async throws
    /// An extra Markdown file in the owner's folder, by name without ".md" (e.g. "helper-checklist").
    func document(_ owner: DeckMemoryOwner, name: String) async throws -> String?
    func saveDocument(_ owner: DeckMemoryOwner, name: String, text: String) async throws

    // MARK: Import and migration
    /// Copies the Markdown files of a Claude Code / Codex memory folder into the owner's notes
    /// (`notes/imported/<label>/`), keeping names so links still work. Copy only: the source is never changed.
    /// Running it again refreshes changed files and skips unchanged ones.
    func importFolder(_ source: URL, into owner: DeckMemoryOwner, label: String?) async throws -> DeckMemoryImportReport
    /// Hoot's old memory (`<app data>/hoot/memory`) copied in as Hoot notes. The original is left untouched.
    func migrateHootMemory() async throws -> DeckMemoryImportReport

    // MARK: Live changes
    /// Every change from now on (app, tool or outside edit). Each call is its own stream; end it by dropping it.
    nonisolated func changes() -> AsyncStream<DeckMemoryChange>
}

public extension DeckMemoryStoring {
    func archiveNote(id: String, reason: String = "archived") async throws -> DeckMemoryNote { try await archiveNote(id: id, reason: reason, replacedBy: nil) }
    func updateNote(id: String, title: String? = nil, body: String? = nil) async throws -> DeckMemoryNote { try await updateNote(id: id, title: title, body: body, type: nil) }
    func topics(_ owner: DeckMemoryOwner) async throws -> [DeckMemoryTopic] { try await topics(owner, job: nil, includeClosed: false) }
    func topics(_ owner: DeckMemoryOwner, includeClosed: Bool) async throws -> [DeckMemoryTopic] { try await topics(owner, job: nil, includeClosed: includeClosed) }
    @discardableResult func ensureOwner(_ owner: DeckMemoryOwner, name: String?) async throws -> DeckMemoryOwnerInfo { try await ensureOwner(owner, name: name, parent: nil) }
    @discardableResult func foldBack(_ helper: DeckMemoryOwner) async throws -> DeckMemoryFoldReport { try await foldBack(helper, into: nil) }
    func updateTopic(_ owner: DeckMemoryOwner, title: String, body: String) async throws -> DeckMemoryTopic { try await updateTopic(owner, title: title, body: body, stamp: nil) }
    func savePlaybook(_ owner: DeckMemoryOwner, rows: [DeckMemoryPlaybookRow]) async throws -> DeckMemoryPlaybook { try await savePlaybook(owner, rows: rows, preface: nil) }
    @discardableResult func ensureOwner(_ owner: DeckMemoryOwner) async throws -> DeckMemoryOwnerInfo { try await ensureOwner(owner, name: nil, parent: nil) }
    func value(_ key: String) async throws -> String? { try await value(key, owner: nil) }
    func addQuestion(owner: DeckMemoryOwner, text: String) async throws -> DeckMemoryQuestion { try await addQuestion(owner: owner, text: text, context: "", refs: []) }
    func diaryHead() async throws -> Int64 { try await diaryHead(session: nil) }
    func handoffs(_ owner: DeckMemoryOwner, topic: String?) async throws -> [DeckMemoryHandoff] { try await handoffs(owner, topic: topic, includeArchived: false) }
}

/// `DeckMemory.store`, `await DeckMemory.ready()`.
public enum DeckMemory {
    /// The store right now. Before the app has opened the real one this is a store whose calls throw
    /// `DeckMemoryError(.unavailable, …)`, so a view can show "Memory is starting…" instead of crashing.
    public static var store: any DeckMemoryStoring { DeckMemoryCenter.shared.store }
    /// The real store, as soon as the app has opened it.
    public static func ready() async -> any DeckMemoryStoring { await DeckMemoryCenter.shared.ready() }
    public static var isReady: Bool { DeckMemoryCenter.shared.isReady }
    /// The memory folder, without waiting (follows a move). Before the store is open: where it will be.
    public static var root: URL { DeckMemoryCenter.shared.root }
}

/// The one place the app's store is kept, plus the hooks other lanes register.
public final class DeckMemoryCenter: @unchecked Sendable {
    public static let shared = DeckMemoryCenter()
    public typealias SessionResolver = @Sendable (_ sessionID: String) async -> DeckMemoryStamp?

    private let lock = NSLock()
    private var real: (any DeckMemoryStoring)?
    private var waiting: [CheckedContinuation<any DeckMemoryStoring, Never>] = []
    private var currentRoot: URL?
    private var resolver: SessionResolver?
    private let unavailable = DeckMemoryUnavailableStore()

    public init() {}

    public var store: any DeckMemoryStoring { lock.withLock { real } ?? unavailable }
    public var isReady: Bool { lock.withLock { real != nil } }
    public var root: URL { lock.withLock { currentRoot } ?? DeckMemoryPaths.root(dataRoot: nil) }

    public func ready() async -> any DeckMemoryStoring {
        await withCheckedContinuation { continuation in
            let existing: (any DeckMemoryStoring)? = lock.withLock {
                if let real { return real }
                waiting.append(continuation); return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
    }

    /// The app calls this once the store is open (and again after a move, with the new root).
    public func install(_ store: any DeckMemoryStoring, root: URL) {
        let resume: [CheckedContinuation<any DeckMemoryStoring, Never>] = lock.withLock {
            real = store; currentRoot = root
            let list = waiting; waiting = []; return list
        }
        resume.forEach { $0.resume(returning: store) }
    }
    public func noteRoot(_ root: URL) { lock.withLock { currentRoot = root } }
    /// Tests and app shutdown.
    public func uninstall() { lock.withLock { real = nil; currentRoot = nil } }

    // MARK: Who a session is (so a tool call from a session is stamped by the app, not by the AI)

    /// L4 AGENTS registers how a session id maps to its SEAT (owner), project, and the hire sitting in it (`agent`, history detail).
    public func setSessionResolver(_ resolver: SessionResolver?) { lock.withLock { self.resolver = resolver } }
    public func stamp(forSession id: String) async -> DeckMemoryStamp? {
        guard let resolver = lock.withLock({ self.resolver }) else { return nil }
        return await resolver(id)
    }
}

/// Where the memory folder is. Pure path rules plus one small pointer file in the app's data folder.
public enum DeckMemoryPaths {
    /// The one name the memory folder has, in every build of the app.
    public static let folderName = "Terminal Deck Memory"
    /// Older spelling, kept so earlier call sites compile.
    public static let realFolderName = folderName
    /// The name of the installed app's own data folder.
    public static let realDataFolderName = "terminaldeck"
    static let pointerFolder = "deck-memory"
    static let pointerFile = "location.json"

    /// The app's own data folder, found the way the app itself finds it: the folder this copy was started with
    /// (`TD_NATIVE_DATA_DIR`), else the installed app's (`~/Library/Application Support/terminaldeck`).
    public static func appDataRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = environment[EngineConfiguration.dataEnvironmentKey]?.trimmingCharacters(in: .whitespaces), custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent("Library/Application Support/" + realDataFolderName, isDirectory: true).standardizedFileURL
    }

    /// Every copy of the app keeps its memory INSIDE its own data folder (Asad, 11 Oct 2026: "everything related to app
    /// as well should be inside app folders, not on home"): `~/Library/Application Support/terminaldeck/Terminal Deck
    /// Memory` for the installed app, `<data folder>/Terminal Deck Memory` for any other copy. One rule for every build.
    /// Move… still puts it wherever the person picks, and "Show in Finder" opens it where it is.
    public static func defaultRoot(dataRoot: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        (dataRoot ?? appDataRoot(home: home)).standardizedFileURL.appendingPathComponent(folderName, isDirectory: true)
    }
    /// Where the installed app kept its memory before 11 Oct 2026 evening: `~/Terminal Deck Memory`.
    static func legacyHomeRoot(home: URL) -> URL { home.appendingPathComponent(folderName, isDirectory: true) }

    /// At start, before memory opens. An installed app whose memory is still in the old home-folder place (and was
    /// never moved there by the person with Move…) gets it moved into its data folder: the whole folder copied, every
    /// file read back and compared byte for byte, then the old folder removed. If any file does not match, nothing is
    /// switched: the memory stays in the old folder, untouched, and is used from there. Never touches a folder that is
    /// not a memory folder (it must hold memory.db), and never fills a new place that already holds something.
    /// Returns one line for the app's log, or nil when there was nothing to do.
    public static func relocateLegacyHomeFolder(dataRoot: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let files = FileManager.default
        let data = (dataRoot ?? appDataRoot(home: home)).standardizedFileURL
        let installed = home.appendingPathComponent("Library/Application Support/" + realDataFolderName, isDirectory: true).standardizedFileURL
        guard data.path == installed.path, readPointer(dataRoot: data) == nil else { return nil }
        let old = legacyHomeRoot(home: home)
        guard files.fileExists(atPath: old.appendingPathComponent("memory.db").path) else { return nil }
        // The same place a fresh start would open: the default, or the first free name beside it when the default holds
        // someone else's files (the folder is never taken over).
        let new = root(dataRoot: data)
        if files.fileExists(atPath: new.appendingPathComponent("memory.db").path) {
            return "Memory: an older memory folder is still at \(old.path). This app uses \(new.path), which already holds memory, and left the older folder as it is."
        }
        if files.fileExists(atPath: new.path) { try? files.removeItem(at: new) }  // free: nothing in it but hidden files
        func everyFile(_ folder: URL) -> [String] {
            ((try? files.subpathsOfDirectory(atPath: folder.path)) ?? []).filter { relative in
                (try? files.attributesOfItem(atPath: folder.appendingPathComponent(relative).path)[.type] as? FileAttributeType) == .typeRegular
            }.sorted()
        }
        let count: Int
        do {
            try files.createDirectory(at: data, withIntermediateDirectories: true)
            try files.copyItem(at: old, to: new)
            let list = everyFile(old)
            guard !list.isEmpty, Set(everyFile(new)) == Set(list) else { throw DeckMemoryError(.moveFailed, "the copy does not hold the same files") }
            for relative in list {
                let a = try Data(contentsOf: old.appendingPathComponent(relative), options: .mappedIfSafe)
                let b = try Data(contentsOf: new.appendingPathComponent(relative), options: .mappedIfSafe)
                guard a == b else { throw DeckMemoryError(.moveFailed, relative + " did not copy correctly") }
            }
            count = list.count
        } catch {
            try? files.removeItem(at: new)
            // Keep using the old place, exactly as it is.
            try? writePointer(.init(root: old.path, previous: []), dataRoot: data)
            return "Memory could NOT be moved into the app's data folder (\(error.localizedDescription)); it stays at \(old.path), untouched, and is used from there."
        }
        // The copy is complete and checked; only now does the old folder go.
        do { try files.removeItem(at: old) } catch {
            return "Memory moved into the app's data folder: \(old.path) -> \(new.path) (\(count) files, every one compared); the old folder could not be removed (\(error.localizedDescription)) and can be deleted by hand."
        }
        return "Memory moved into the app's data folder: \(old.path) -> \(new.path) (\(count) files, every one compared before the old folder was removed)."
    }
    static func pointer(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(pointerFolder, isDirectory: true).appendingPathComponent(pointerFile)
    }
    struct Pointer: Codable { var root: String; var previous: [String] }
    static func readPointer(dataRoot: URL) -> Pointer? {
        guard let data = try? Data(contentsOf: pointer(dataRoot: dataRoot)) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }
    static func writePointer(_ value: Pointer, dataRoot: URL) throws {
        let file = pointer(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
    }
    /// The folder in use: the moved-to place if the person moved it, else the default. A default folder that
    /// already exists with other things in it (and is not a memory folder) is never taken over: the memory
    /// goes next to it, under the first free name ("<name> 2").
    public static func root(dataRoot: URL?) -> URL {
        let data = dataRoot ?? appDataRoot()
        if let saved = readPointer(dataRoot: data), saved.root.hasPrefix("/") {
            return URL(fileURLWithPath: saved.root, isDirectory: true)
        }
        let wanted = defaultRoot(dataRoot: data)
        if isFreeOrMemory(wanted) { return wanted }
        // Taken by something else: the first free name beside it ("Terminal Deck Memory 2", …).
        for number in 2...50 {
            let other = wanted.deletingLastPathComponent().appendingPathComponent(wanted.lastPathComponent + " \(number)", isDirectory: true)
            if isFreeOrMemory(other) { return other }
        }
        return wanted.deletingLastPathComponent().appendingPathComponent(wanted.lastPathComponent + " " + UUID().uuidString.prefix(8), isDirectory: true)
    }
    /// True when nothing is there, the folder is empty, or it is already a memory folder (it holds memory.db).
    public static func isFreeOrMemory(_ folder: URL) -> Bool {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else { return false }
        if files.fileExists(atPath: folder.appendingPathComponent("memory.db").path) { return true }
        return ((try? files.contentsOfDirectory(atPath: folder.path)) ?? ["?"]).allSatisfy { $0.hasPrefix(".") }
    }
    public static func location(dataRoot: URL?) -> DeckMemoryLocation {
        let data = dataRoot ?? appDataRoot()
        let previous = readPointer(dataRoot: data)?.previous.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? []
        return .init(root: root(dataRoot: data), defaultRoot: defaultRoot(dataRoot: data), previousRoots: previous)
    }
}

/// What `DeckMemory.store` is before the app has opened the real store: every call says so plainly.
struct DeckMemoryUnavailableStore: DeckMemoryStoring {
    private var gone: DeckMemoryError { .init(.unavailable, "Memory is still starting. Try again in a moment.") }
    func location() async -> DeckMemoryLocation { DeckMemoryPaths.location(dataRoot: nil) }
    func move(to newRoot: URL) async throws -> DeckMemoryMoveReport { throw gone }
    func reindex() async throws -> DeckMemoryReindexReport { throw gone }
    func backup() async throws -> URL { throw gone }
    func writeStartHere() async throws { throw gone }
    func owners() async throws -> [DeckMemoryOwnerInfo] { throw gone }
    func ensureOwner(_ owner: DeckMemoryOwner, name: String?, parent: DeckMemoryOwner?) async throws -> DeckMemoryOwnerInfo { throw gone }
    func template(_ category: DeckMemoryCategory) async throws -> DeckMemoryTemplate { throw gone }
    func saveTemplate(_ template: DeckMemoryTemplate) async throws -> DeckMemoryTemplate { throw gone }
    func card(_ owner: DeckMemoryOwner) async throws -> DeckMemoryCard { throw gone }
    func assembledCard(_ owner: DeckMemoryOwner) async throws -> DeckMemoryAssembledCard { throw gone }
    func saveCard(_ owner: DeckMemoryOwner, text: String) async throws -> DeckMemoryCard { throw gone }
    func cardLimit(_ owner: DeckMemoryOwner) async throws -> Int { throw gone }
    func setCardLimit(_ limit: Int, for owner: DeckMemoryOwner) async throws { throw gone }
    func addNote(_ draft: DeckMemoryNoteDraft) async throws -> DeckMemoryNote { throw gone }
    func updateNote(id: String, title: String?, body: String?, type: DeckMemoryNoteType?) async throws -> DeckMemoryNote { throw gone }
    func archiveNote(id: String, reason: String, replacedBy: String?) async throws -> DeckMemoryNote { throw gone }
    func restoreNote(id: String) async throws -> DeckMemoryNote { throw gone }
    func setShortTitle(noteID: String, short: String, by: DeckMemoryShortTitle.Maker) async throws -> DeckMemoryNote { throw gone }
    func note(id: String) async throws -> DeckMemoryNote? { throw gone }
    func notes(_ query: DeckMemoryNoteQuery) async throws -> [DeckMemoryNote] { throw gone }
    func history(ofNote id: String) async throws -> [DeckMemoryNote] { throw gone }
    func appendDiary(_ draft: DeckMemoryDiaryDraft) async throws -> DeckMemoryDiaryEntry { throw gone }
    func appendDiary(_ drafts: [DeckMemoryDiaryDraft]) async throws -> [DeckMemoryDiaryEntry] { throw gone }
    func diary(_ query: DeckMemoryDiaryQuery) async throws -> [DeckMemoryDiaryEntry] { throw gone }
    func diary(around id: Int64, before: Int, after: Int) async throws -> [DeckMemoryDiaryEntry] { throw gone }
    func diaryHead(session: String?) async throws -> Int64 { throw gone }
    func saveHandoff(_ draft: DeckMemoryHandoffDraft) async throws -> DeckMemoryHandoff { throw gone }
    func updateHandoff(id: String, title: String?, markdown: String?) async throws -> DeckMemoryHandoff { throw gone }
    func handoff(id: String) async throws -> DeckMemoryHandoff? { throw gone }
    func handoffs(_ owner: DeckMemoryOwner, topic: String?, includeArchived: Bool) async throws -> [DeckMemoryHandoff] { throw gone }
    func allHandoffs(_ owner: DeckMemoryOwner, includeArchived: Bool) async throws -> [DeckMemoryHandoff] { throw gone }
    func archiveHandoff(id: String, reason: String) async throws -> DeckMemoryHandoff { throw gone }
    func restoreHandoff(id: String) async throws -> DeckMemoryHandoff { throw gone }
    func markRewound(owner: DeckMemoryOwner, conversation: String, after: Int64) async throws -> DeckMemoryRewind { throw gone }
    func undoRewind(id: Int64) async throws -> DeckMemoryRewind { throw gone }
    func rewinds(owner: DeckMemoryOwner?, conversation: String?) async throws -> [DeckMemoryRewind] { throw gone }
    func updateBoard(_ update: DeckMemoryBoardUpdate) async throws -> DeckMemoryBoardRow { throw gone }
    func board(_ query: DeckMemoryBoardQuery) async throws -> [DeckMemoryBoardRow] { throw gone }
    func boardChanges(since: Date, owner: DeckMemoryOwner?) async throws -> [DeckMemoryBoardChange] { throw gone }
    func archiveBoardRow(id: String) async throws -> DeckMemoryBoardRow { throw gone }
    func topics(_ owner: DeckMemoryOwner, job: String?, includeClosed: Bool) async throws -> [DeckMemoryTopic] { throw gone }
    func foldBack(_ helper: DeckMemoryOwner, into parent: DeckMemoryOwner?) async throws -> DeckMemoryFoldReport { throw gone }
    func topic(_ owner: DeckMemoryOwner, id: String) async throws -> DeckMemoryTopic? { throw gone }
    func updateTopic(_ owner: DeckMemoryOwner, title: String, body: String, stamp: DeckMemoryStamp?) async throws -> DeckMemoryTopic { throw gone }
    func setTopic(_ owner: DeckMemoryOwner, id: String, open: Bool) async throws -> DeckMemoryTopic { throw gone }
    func playbook(_ owner: DeckMemoryOwner) async throws -> DeckMemoryPlaybook { throw gone }
    func savePlaybook(_ owner: DeckMemoryOwner, rows: [DeckMemoryPlaybookRow], preface: String?) async throws -> DeckMemoryPlaybook { throw gone }
    func playbookRow(_ owner: DeckMemoryOwner, job: String) async throws -> DeckMemoryPlaybookRow? { throw gone }
    func search(_ query: DeckMemorySearchQuery) async throws -> DeckMemorySearchResult { throw gone }
    func addQuestion(owner: DeckMemoryOwner, text: String, context: String, refs: [String]) async throws -> DeckMemoryQuestion { throw gone }
    func questions(owner: DeckMemoryOwner?, openOnly: Bool) async throws -> [DeckMemoryQuestion] { throw gone }
    func answerQuestion(id: Int64, answer: String) async throws -> DeckMemoryQuestion { throw gone }
    func dismissQuestion(id: Int64) async throws -> DeckMemoryQuestion { throw gone }
    func reopenQuestion(id: Int64) async throws -> DeckMemoryQuestion { throw gone }
    func value(_ key: String, owner: DeckMemoryOwner?) async throws -> String? { throw gone }
    func setValue(_ value: String?, key: String, owner: DeckMemoryOwner?) async throws { throw gone }
    func document(_ owner: DeckMemoryOwner, name: String) async throws -> String? { throw gone }
    func saveDocument(_ owner: DeckMemoryOwner, name: String, text: String) async throws { throw gone }
    func importFolder(_ source: URL, into owner: DeckMemoryOwner, label: String?) async throws -> DeckMemoryImportReport { throw gone }
    func migrateHootMemory() async throws -> DeckMemoryImportReport { throw gone }
    nonisolated func changes() -> AsyncStream<DeckMemoryChange> { AsyncStream { $0.finish() } }
}
