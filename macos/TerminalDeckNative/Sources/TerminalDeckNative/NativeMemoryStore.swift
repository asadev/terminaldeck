import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Actions other lanes provide for the Memory area. A nil action hides its button (never a dead click).
@MainActor
enum NativeMemoryActions {
    /// M2 FLOW: run the note-writing helper now for this owner key. Returns a short sentence.
    static var runHelper: (@MainActor (String) async throws -> String)?
    /// M2 FLOW: run the tidy-up now for this owner key. Returns a short sentence.
    static var runTidy: (@MainActor (String) async throws -> String)?
}

/// One owner's memory, as the Memory area shows it. Reads and writes go straight to M1's store
/// (DeckMemory); every change anywhere (app, tool, a file edited in Finder) arrives as
/// `.deckMemoryChanged` and reloads only the part it touched.
@MainActor @Observable
final class NativeMemoryStore {
    private static var stores: [String: NativeMemoryStore] = [:]
    static func of(_ owner: DeckMemoryOwner) -> NativeMemoryStore {
        if let existing = stores[owner.key] { return existing }
        let made = NativeMemoryStore(owner: owner); stores[owner.key] = made; return made
    }
    /// `stop()` on the store kept for this owner, never making one.
    static func stop(_ owner: DeckMemoryOwner) { stores[owner.key]?.stop() }

    let owner: DeckMemoryOwner
    /// A fixture never touches the real store (offscreen pictures).
    let fixture: Bool
    var card: DeckMemoryCard?
    /// The category template this seat follows (nil for a project's shared space).
    var template: DeckMemoryTemplate?
    var notes: [DeckMemoryNote] = []
    var archivedNotes: [DeckMemoryNote] = []
    var topics: [DeckMemoryTopic] = []
    var playbook: DeckMemoryPlaybook?
    var board: [DeckMemoryBoardRow] = []
    var diary: [DeckMemoryDiaryEntry] = []
    var questions: [DeckMemoryQuestion] = []
    var location: DeckMemoryLocation?
    var settings: [String: String] = [:]
    var checklist = ""
    /// The top rules' short titles (rule key → 3 to 6 words), made by the memory helper.
    var ruleTitles: [String: String] = [:]
    var loaded = false
    var problem: String?
    var status: String?
    var busy: String?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// How many screens show this owner now (`start` adds one, `stop` takes it back).
    @ObservationIgnored private(set) var showing = 0

    init(owner: DeckMemoryOwner, fixture: Bool = false) { self.owner = owner; self.fixture = fixture }

    private var memory: any DeckMemoryStoring { get async { await DeckMemory.ready() } }

    func start() {
        guard !fixture else { loaded = true; return }
        showing += 1
        if !watching {
            watching = true
            observer = NotificationCenter.default.addObserver(forName: .deckMemoryChanged, object: nil, queue: .main) { [weak self] note in
                guard let change = note.userInfo?["change"] as? DeckMemoryChange else { return }
                Task { @MainActor in self?.changed(change) }
            }
        }
        Task { await reloadAll() }
    }

    /// U143 (#177): the last screen showing this owner went away. It stops watching and lets the store
    /// go, so a seat opened once is not kept and reloaded on every change for the rest of the run.
    func stop() {
        guard !fixture, showing > 0 else { return }
        showing -= 1
        guard showing == 0 else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; watching = false
        if Self.stores[owner.key] === self { Self.stores[owner.key] = nil }
    }

    private func changed(_ change: DeckMemoryChange) {
        // The board, questions, settings and the folder are shared; the rest belongs to one owner.
        let mine = change.owner == nil || change.owner == owner || change.owner?.projectID != nil && change.owner?.projectID == owner.projectID
        Task {
            switch change.area {
            case .card: await loadCard()
            case .notes, .index: if mine { await loadNotes() }
            case .topics: if mine { await load { self.topics = try await $0.topics(self.owner, includeClosed: true) } }
            case .playbook: if mine { await loadPlaybook() }
            case .board: await loadBoard()
            case .diary: if mine { await loadDiary() }
            case .questions: await load { self.questions = try await $0.questions(owner: nil, openOnly: false) }
            case .settings, .documents: await loadSettings(); await loadCard()
            case .templates: await loadCard()
            case .folder: await load { self.location = await $0.location() }
            }
        }
    }

    func reloadAll() async {
        await loadCard()
        await loadNotes()
        await load { self.topics = try await $0.topics(self.owner, includeClosed: true) }
        await loadPlaybook()
        await loadBoard()
        await loadDiary()
        await load { self.questions = try await $0.questions(owner: nil, openOnly: false) }
        await loadSettings()
        await load { self.location = await $0.location() }
        loaded = true
    }
    private func load(_ work: @MainActor (any DeckMemoryStoring) async throws -> Void) async {
        do { try await work(await memory); } catch { problem = error.localizedDescription }
    }
    /// The seat's own card and its category template (a template edit changes every seat's card).
    private func loadCard() async {
        await load {
            self.card = try await $0.card(self.owner)
            if let category = self.owner.category { self.template = try await $0.template(category) }
            self.ruleTitles = await DeckMemoryShortTitles.ruleTitles($0)
        }
    }
    private func loadNotes() async {
        await load {
            self.notes = try await $0.notes(.init(owner: self.owner, limit: 500))
            self.archivedNotes = try await $0.notes(.init(owner: self.owner, archivedOnly: true, limit: 500))
        }
    }
    private func loadPlaybook() async {
        guard owner.hasPlaybook else { return }
        await load { self.playbook = try await $0.playbook(self.owner) }
    }
    var boardEverything = false
    func loadBoard() async {
        await load { self.board = try await $0.board(.init(owner: self.boardEverything ? .hoot : self.owner, limit: 300)) }
    }
    private func loadDiary() async {
        await load { self.diary = try await $0.diary(.init(owner: self.owner, limit: 160, newestFirst: true, includeRewound: true)) }
    }
    private func loadSettings() async {
        await load {
            var next: [String: String] = [:]
            for key in [DeckMemoryKeys.helperLastRun, DeckMemoryKeys.tidyLastRun] {
                next[key] = try await $0.value(key, owner: self.owner)
            }
            for key in [DeckMemoryKeys.helperAI, DeckMemoryKeys.helperModel] { next[key] = try await $0.value(key, owner: nil) }
            self.settings = next
            self.checklist = try await $0.document(.hoot, name: "helper-checklist") ?? ""
        }
    }

    /// One change: shows "Saved" or the plain reason it did not save. The store's own change
    /// notification refreshes the lists. False when another change is still running: nothing was
    /// taken, so an editor stays open with its text.
    @discardableResult
    func act(_ label: String, done: String = "Saved", _ work: @escaping @MainActor (any DeckMemoryStoring) async throws -> String?) -> Bool {
        guard !fixture else { return true }
        guard busy == nil else { problem = "Still saving the last change. Try again in a moment."; return false }
        busy = label; problem = nil; status = nil
        Task {
            defer { busy = nil }
            do { status = try await work(await memory) ?? done } catch { problem = error.localizedDescription }
        }
        return true
    }

    // MARK: Words

    static func when(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }
    static func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }
    /// A saved setting that may be a date (ISO or seconds) or a plain sentence.
    static func stamp(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "never" }
        if let date = ISO8601DateFormatter().date(from: raw) { return when(date) }
        if let seconds = Double(raw), seconds > 1_000_000 { return when(Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)) }
        return raw
    }
    /// The project's logo (or its letter tile) for a row that names a project.
    func projectIcon(_ id: String?) -> NSImage? {
        guard let id, !id.isEmpty else { return nil }
        return DeckRowIcon.project(id: id, in: NativePROJLabels.shared.projects)
    }
    func projectName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return NativePROJLabels.shared.projects.first { $0.id == id }?.name ?? id
    }
}
