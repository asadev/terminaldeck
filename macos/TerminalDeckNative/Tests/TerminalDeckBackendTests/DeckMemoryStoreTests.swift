import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// A clock that moves one second per reading, so "newer" is never a tie.
private final class DeckMemoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_791_000_000)
    func tick() -> Date { lock.withLock { current = current.addingTimeInterval(1); return current } }
    func jump(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Stands in for the on-device model: texts about the same subject get the same direction.
private struct DeckMemoryTestEmbedder: DeckMemoryEmbedding {
    static let subjects: [[String]] = [
        ["ship", "shipped", "release", "released", "publish", "published", "deploy", "testflight"],
        ["colour", "color", "blue", "button", "buttons", "grey", "design"],
        ["login", "password", "sign", "account", "crash"]
    ]
    var model: String { "test-subjects-1" }
    func vector(for text: String) async -> [Float]? {
        let words = Set(DeckMemoryStore.words(text))
        let vector = Self.subjects.map { subject in Float(subject.filter(words.contains).count) }
        return vector   // a text about none of the subjects points nowhere, so it matches nothing by meaning
    }
}

final class DeckMemoryStoreTests: XCTestCase {
    private var folders: [URL] = []
    private let iosSeat = DeckMemoryOwner.role(project: "imatch", role: "ios")

    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }
    func testFileEventsOnlyIndexNamedPathsAndRescanFindsTheRest() async throws {
        let (store, root, data) = try await open()
        let one = try await store.addNote(.init(title: "One", body: "original", type: .decision, stamp: .hoot))
        let two = try await store.addNote(.init(title: "Two", body: "original", type: .decision, stamp: .hoot))
        try write(root, one.path, read(root, one.path).replacingOccurrences(of: "original", with: "changed one"))
        try write(root, two.path, read(root, two.path).replacingOccurrences(of: "original", with: "changed two"))
        let batch = (0..<1_200).map { root.appendingPathComponent("hoot/notes/absent-\($0).md").path } + [root.appendingPathComponent(one.path).path]
        await store.filesChanged(batch, rescan: false, base: root.path)
        let first = try await store.search(.init("changed", mode: .words))
        XCTAssertEqual(first.hits.map(\.ref), [one.id], "an event must not walk unrelated notes")
        await store.filesChanged([], rescan: true, base: root.path)
        let both = try await store.search(.init("changed", mode: .words))
        XCTAssertEqual(Set(both.hits.map(\.ref)), Set([one.id, two.id]))
        try write(data, "outside.md", "# Outside\n\nLeave this file alone.\n")
        let shortcut = root.appendingPathComponent("hoot/notes/shortcut")
        try FileManager.default.createSymbolicLink(at: shortcut, withDestinationURL: data)
        await store.filesChanged([shortcut.path, shortcut.appendingPathComponent("outside.md").path], rescan: false, base: root.path)
        XCTAssertEqual(read(data, "outside.md"), "# Outside\n\nLeave this file alone.\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent(one.path).deletingLastPathComponent())
        await store.filesChanged([root.appendingPathComponent(one.path).deletingLastPathComponent().path], rescan: false, base: root.path)
        let gone = try await store.notes(.init())
        XCTAssertTrue(gone.isEmpty, "a deleted directory marks its indexed children missing")
        await store.close()
    }

    func testNoteListsReuseIndexedTextUntilTheFileChanges() async throws {
        let (store, root, _) = try await open()
        let note = try await store.addNote(.init(title: "Cached", body: "original", type: .decision, stamp: .hoot))
        // The index is the last observed version until the file event arrives.
        try write(root, note.path, read(root, note.path).replacingOccurrences(of: "original", with: "updated"))
        let cached = try await store.notes(.init())
        XCTAssertEqual(cached.first?.body, "original")
        await store.filesChanged([root.appendingPathComponent(note.path).path], rescan: false, base: root.path)
        let updated = try await store.notes(.init())
        XCTAssertEqual(updated.first?.body, "updated")
        await store.close()
    }

    private func temp(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("td-deck-memory-" + name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        // The same spelling the store keeps, so paths compare equal.
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }
    private func open(embedder: (any DeckMemoryEmbedding)? = nil) async throws -> (store: DeckMemoryStore, root: URL, data: URL) {
        let data = try temp("data"), root = try temp("root").appendingPathComponent("Memory")
        let clock = DeckMemoryTestClock()
        let store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: embedder, watch: false, now: { clock.tick() })
        return (store, root, data)
    }
    private func exists(_ root: URL, _ relative: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) }
    private func read(_ root: URL, _ relative: String) -> String { (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? "" }
    private func write(_ root: URL, _ relative: String, _ text: String) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    // MARK: Layout

    func testOpeningMakesTheFolderAnyAIAppCanPickUp() async throws {
        let (store, root, _) = try await open()
        for file in ["START-HERE.md", "CLAUDE.md", "AGENTS.md", "GEMINI.md", "memory.db", "hoot/card.md", "hoot/playbook.md",
                     "templates/orchestrator/card.md", "templates/lead/checklist.md", "templates/agent/settings.md"] {
            XCTAssertTrue(exists(root, file), file)
        }
        XCTAssertTrue(read(root, "CLAUDE.md").contains("START-HERE.md"))
        XCTAssertTrue(read(root, "START-HERE.md").contains("Memory belongs to the **seat**"))
        // A START-HERE the person took over (marker removed) is left alone.
        try write(root, "START-HERE.md", "mine now")
        try await store.writeStartHere()
        XCTAssertEqual(read(root, "START-HERE.md"), "mine now")
        await store.close()
    }

    func testWhereTheFolderSitsFollowsTheAppsDataFolder() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let support = home.appendingPathComponent("Library/Application Support")
        // The installed app keeps it inside its own data folder too, never in the home folder (Asad, 11 Oct).
        XCTAssertEqual(DeckMemoryPaths.defaultRoot(dataRoot: support.appendingPathComponent("terminaldeck"), home: home).path,
                       "/Users/someone/Library/Application Support/terminaldeck/Terminal Deck Memory")
        // The default home layout is tested with an explicit empty environment.
        // A nil data root must also respect an isolated runner's data override.
        XCTAssertEqual(DeckMemoryPaths.appDataRoot(environment: [:], home: home).path,
                       "/Users/someone/Library/Application Support/terminaldeck")
        XCTAssertEqual(DeckMemoryPaths.defaultRoot(dataRoot: nil, home: home),
                       DeckMemoryPaths.appDataRoot(home: home).appendingPathComponent("Terminal Deck Memory", isDirectory: true))
        // Any other copy of the app keeps a folder of the SAME name inside its own data folder: one name, no second one.
        XCTAssertEqual(DeckMemoryPaths.defaultRoot(dataRoot: support.appendingPathComponent("Another Copy"), home: home).path,
                       "/Users/someone/Library/Application Support/Another Copy/Terminal Deck Memory")
        // A scratch or test data folder never reaches into the person's home.
        XCTAssertEqual(DeckMemoryPaths.defaultRoot(dataRoot: URL(fileURLWithPath: "/Volumes/Scratch/td/data"), home: home).path, "/Volumes/Scratch/td/data/Terminal Deck Memory")
    }

    func testOwnerSpellings() {
        XCTAssertEqual(iosSeat.key, "role:imatch/ios")
        XCTAssertEqual(iosSeat.folder, "projects/imatch/roles/ios")
        XCTAssertEqual(DeckMemoryOwner(key: "role:imatch/ios"), iosSeat)
        XCTAssertEqual(DeckMemoryOwner(folder: "projects/imatch/roles/ios"), iosSeat)
        XCTAssertEqual(DeckMemoryOwner("roles/writer"), .role(project: nil, role: "writer"))
        XCTAssertEqual(DeckMemoryOwner("projects/crm/lead"), .lead("crm"))
        XCTAssertEqual(DeckMemoryOwner(key: "agent:old-one"), .role(project: nil, role: "old-one"))
        XCTAssertEqual(iosSeat.category, .agent); XCTAssertEqual(DeckMemoryOwner.lead("crm").category, .lead)
        XCTAssertEqual(DeckMemoryOwner.hoot.category, .orchestrator); XCTAssertNil(DeckMemoryOwner.project("crm").category)
        XCTAssertNil(DeckMemoryOwner(key: "role:../etc"))
    }

    // MARK: Notes: supersede, archive, labels

    func testANewerNoteSupersedesAnOlderOneAndKeepsTheLink() async throws {
        let (store, root, _) = try await open()
        let old = try await store.addNote(.init(title: "Ship order", body: "Phone first.", type: .decision, stamp: .hoot, source: "helper"))
        let new = try await store.addNote(.init(title: "Ship order", body: "Mac first, phone later.", type: .decision, stamp: .hoot, supersedes: old.id, source: "helper"))
        XCTAssertEqual(new.supersedes, old.id)
        XCTAssertTrue(new.body.contains("Replaces [[" + DeckMemoryStore.stem(old.path) + "]]"), new.body)
        let archived = try await store.note(id: old.id)
        XCTAssertEqual(archived?.supersededBy, new.id)
        XCTAssertEqual(archived?.archiveReason, "superseded")
        XCTAssertEqual(archived?.path, "archive/" + old.path)
        // The old note is kept, word for word, in the archive; it is gone from where it was.
        XCTAssertTrue(exists(root, "archive/" + old.path)); XCTAssertFalse(exists(root, old.path))
        XCTAssertTrue(read(root, "archive/" + old.path).contains("Phone first."))
        XCTAssertTrue(read(root, "archive/" + old.path).contains("superseded_by: " + new.id))
        let live = try await store.notes(.init(owner: .hoot)).map(\.id)
        XCTAssertEqual(live, [new.id])
        let all = try await store.notes(.init(owner: .hoot, includeArchived: true)).map(\.id)
        XCTAssertEqual(Set(all), [new.id, old.id])
        let history = try await store.history(ofNote: new.id).map(\.id)
        XCTAssertEqual(history, [old.id])
        do { _ = try await store.addNote(.init(title: "x", body: "y", stamp: .hoot, supersedes: "n-nope")); XCTFail("a missing note cannot be replaced") }
        catch let error as DeckMemoryError { XCTAssertEqual(error.code, .notFound) }
        await store.close()
    }

    func testNothingIsDeletedOnlyArchivedAndItComesBack() async throws {
        let (store, root, _) = try await open()
        let note = try await store.addNote(.init(title: "Buttons are blue", body: "One blue main action per screen.", type: .preference, stamp: .hoot))
        let archived = try await store.archiveNote(id: note.id, reason: "out of date")
        XCTAssertTrue(archived.isArchived); XCTAssertEqual(archived.archiveReason, "out of date")
        XCTAssertTrue(exists(root, "archive/" + note.path))
        let listed = try await store.notes(.init(owner: .hoot))
        XCTAssertTrue(listed.isEmpty)
        let onlyArchived = try await store.notes(.init(owner: .hoot, archivedOnly: true)).map(\.id)
        XCTAssertEqual(onlyArchived, [note.id])
        let back = try await store.restoreNote(id: note.id)
        XCTAssertFalse(back.isArchived); XCTAssertEqual(back.path, note.path)
        XCTAssertTrue(exists(root, note.path)); XCTAssertFalse(exists(root, "archive/" + note.path))
        XCTAssertEqual(back.body, "One blue main action per screen.")
        // An edit keeps the earlier text too.
        _ = try await store.updateNote(id: note.id, title: nil, body: "One blue main action per screen. Segmented controls stay grey.", type: nil)
        let versions = DeckMemoryFiles.markdown(under: root.appendingPathComponent("archive/versions"))
        XCTAssertEqual(versions.count, 1)
        XCTAssertTrue(read(root, "archive/versions/" + versions[0]).contains("One blue main action per screen.\n"))
        await store.close()
    }

    func testEveryNoteAndDiaryRowCarriesTheAppsLabels() async throws {
        let (store, root, _) = try await open()
        let stamp = DeckMemoryStamp(owner: iosSeat, session: "sess-1", agent: "hire-1", hand: 2, job: "fix-login-crash")
        XCTAssertEqual(stamp.project, "imatch")
        let note = try await store.addNote(.init(title: "Login crash cause", body: "A nil token after resume.", type: .result, stamp: stamp, source: "helper"))
        XCTAssertEqual(note.labels.owner, iosSeat); XCTAssertEqual(note.labels.category, .agent); XCTAssertEqual(note.labels.seat, "role:imatch/ios")
        XCTAssertEqual(note.labels.project, "imatch"); XCTAssertEqual(note.labels.session, "sess-1"); XCTAssertEqual(note.labels.hire, "hire-1")
        XCTAssertEqual(note.labels.hand, 2); XCTAssertEqual(note.labels.job, "fix-login-crash"); XCTAssertEqual(note.labels.type, "result")
        XCTAssertEqual(note.type, .result); XCTAssertEqual(note.source, "helper")
        XCTAssertTrue(note.path.hasPrefix("projects/imatch/roles/ios/notes/"))
        let text = read(root, note.path)
        for line in ["id: " + note.id, "type: result", "seat: role:imatch/ios", "category: agent", "project: imatch", "session: sess-1", "hand: 2", "job: fix-login-crash", "hire: hire-1", "source: helper"] {
            XCTAssertTrue(text.contains(line + "\n"), line)
        }
        XCTAssertTrue(text.contains("date: " + DeckMemoryFiles.stamp(note.labels.date)))
        let entry = try await store.appendDiary(.init(stamp: stamp, role: .user, text: "why does it crash after resume?", conversation: "sess-1"))
        XCTAssertEqual(entry.labels.owner, iosSeat); XCTAssertEqual(entry.labels.hand, 2); XCTAssertEqual(entry.labels.job, "fix-login-crash")
        XCTAssertEqual(entry.labels.type, "user"); XCTAssertEqual(entry.labels.hire, "hire-1")
        let byJob = try await store.notes(.init(job: "fix-login-crash")).map(\.id)
        XCTAssertEqual(byJob, [note.id])
        await store.close()
    }

    // MARK: Seats and templates (spec 3a)

    func testMemoryBelongsToTheSeatNotToTheHire() async throws {
        let (store, _, _) = try await open()
        let made = try await store.ensureOwner(iosSeat, name: "iOS developer")
        XCTAssertEqual(made.name, "iOS developer")
        _ = try await store.addNote(.init(title: "Use the dev copy for rounds", body: "Install the real app per batch.", type: .lesson,
                                          stamp: .init(owner: iosSeat, session: "s1", agent: "first-hire")))
        // The first hire is deleted: nothing is called. A new hire sits down in the same seat.
        _ = try await store.ensureOwner(iosSeat, name: "second hire's own name")
        let seen = try await store.notes(.init(owner: iosSeat))
        XCTAssertEqual(seen.map(\.title), ["Use the dev copy for rounds"])
        XCTAssertEqual(seen.first?.labels.hire, "first-hire")
        let seats = try await store.owners()
        let seat = try XCTUnwrap(seats.first { $0.owner == iosSeat })
        XCTAssertEqual(seat.name, "iOS developer"); XCTAssertTrue(seat.hasMemory); XCTAssertEqual(seat.notes, 1); XCTAssertEqual(seat.category, .agent)
        XCTAssertTrue(seats.contains { $0.owner == .project("imatch") })
        await store.close()
    }

    func testASeatsCardIsTheCategoryTemplatePlusItsOwnAdditions() async throws {
        let (store, root, _) = try await open()
        let other = DeckMemoryOwner.role(project: nil, role: "writer")
        _ = try await store.saveCard(iosSeat, text: "# iOS developer\n\n## Top rules\n- Never touch a simulator you did not boot.\n")
        _ = try await store.saveCard(other, text: "# Writer\n")
        var template = try await store.template(.agent)
        XCTAssertFalse(template.has(.playbook)); XCTAssertEqual(template.handsPerSeat, 3)
        template.card = "# Agent\n\n## Top rules\n- Report in three lines.\n"
        template.handsPerSeat = 5; template.helperModel = "haiku-never"; template.parts.insert(.playbook)
        let saved = try await store.saveTemplate(template)
        XCTAssertEqual(saved.handsPerSeat, 5); XCTAssertTrue(saved.has(.playbook)); XCTAssertEqual(saved.helperModel, "haiku-never")
        let first = try await store.assembledCard(iosSeat), second = try await store.assembledCard(other)
        // One edit of the template reached both seats.
        XCTAssertTrue(first.text.hasPrefix("# Agent")); XCTAssertTrue(second.text.hasPrefix("# Agent"))
        XCTAssertTrue(first.text.hasSuffix("- Never touch a simulator you did not boot."))
        XCTAssertEqual(first.topRules, ["- Report in three lines.", "- Never touch a simulator you did not boot."])
        XCTAssertEqual(first.shared, "# Agent\n\n## Top rules\n- Report in three lines.\n")
        let own = try await store.card(iosSeat)
        XCTAssertEqual(own.text, "# iOS developer\n\n## Top rules\n- Never touch a simulator you did not boot.\n")
        // The template is plain files; an edit made outside the app is picked up.
        try write(root, "templates/agent/settings.md", "- parts: card, notes\n- refresh at: 0.7\n- helper ai: codex\n- hands per seat: 2\n- hands per project: 4\n")
        let report = try await store.reindex()
        XCTAssertEqual(report.changed, 1)
        let edited = try await store.template(.agent)
        XCTAssertEqual(edited.parts, [.card, .notes]); XCTAssertEqual(edited.helperAI, "codex")
        XCTAssertEqual(edited.handsPerSeat, 2); XCTAssertEqual(edited.handsPerProject, 4)
        // The earlier template text was kept.
        XCTAssertFalse(DeckMemoryFiles.markdown(under: root.appendingPathComponent("archive/versions/templates/agent")).isEmpty)
        await store.close()
    }

    func testACardOverItsCapIsReportedNeverCut() async throws {
        let (store, root, _) = try await open()
        var template = try await store.template(.agent)
        template.card = String(repeating: "t", count: 100); template.cardLimit = 300
        _ = try await store.saveTemplate(template)
        let long = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)   // 499 characters
        let card = try await store.saveCard(iosSeat, text: long)
        XCTAssertEqual(card.text, long)
        XCTAssertEqual(read(root, iosSeat.cardPath), long, "the whole card is on disk")
        let assembled = try await store.assembledCard(iosSeat)
        XCTAssertEqual(assembled.characters, 100 + 2 + 499)
        XCTAssertEqual(assembled.overBy, 301); XCTAssertEqual(card.overBy, 301); XCTAssertFalse(card.fits)
        XCTAssertTrue(assembled.text.hasSuffix(long))
        let brief = try await DeckMemoryBrief.opening(store, owner: iosSeat)
        XCTAssertEqual(brief.cardOverBy, 301); XCTAssertTrue(brief.text.contains(long))
        try await store.setCardLimit(1000, for: iosSeat)
        let fits = try await store.assembledCard(.role(project: nil, role: "someone-else"))
        XCTAssertEqual(fits.limit, 1000, "the cap belongs to the category, not to one seat")
        await store.close()
    }

    // MARK: Board

    func testBoardResultsAreAttemptedReportedVerified() async throws {
        let (store, _, _) = try await open()
        let id = DeckMemoryBoardRow.rowID(.session, "s1")
        let stamp = DeckMemoryStamp(owner: iosSeat, session: "s1", agent: "hire-1", hand: 1, job: "fix-login-crash")
        var row = try await store.updateBoard(.init(id: id, kind: .session, stamp: stamp, title: "Login crash", doing: "reading the crash log"))
        XCTAssertNil(row.state)
        let started = row.updatedAt
        row = try await store.updateBoard(.init(id: id, kind: .session, stamp: stamp, lastResult: "Patched the token check."))
        XCTAssertEqual(row.state, .attempted)
        row = try await store.updateBoard(.init(id: id, kind: .session, stamp: stamp, state: .reported))
        XCTAssertEqual(row.state, .reported)
        do { _ = try await store.updateBoard(.init(id: id, kind: .session, stamp: stamp, state: .verified)); XCTFail("verified needs proof") }
        catch let error as DeckMemoryError { XCTAssertEqual(error.code, .proofRequired) }
        let unchanged = try await store.board(.init(session: "s1"))
        XCTAssertEqual(unchanged.first?.state, .reported)
        row = try await store.updateBoard(.init(id: id, kind: .session, stamp: stamp, state: .verified, proof: "LoginResumeTests passed on build 412"))
        XCTAssertEqual(row.state, .verified); XCTAssertEqual(row.labels.hand, 1); XCTAssertEqual(row.labels.job, "fix-login-crash")
        // A new result is a new claim: it starts as attempted and does not inherit the old proof.
        row = try await store.updateBoard(.init(id: id, kind: .session, stamp: stamp, lastResult: "Also fixed sign-out.", waitingForUser: "Pick the wording"))
        XCTAssertEqual(row.state, .attempted); XCTAssertEqual(row.proof, ""); XCTAssertTrue(row.isWaiting)
        let changes = try await store.boardChanges(since: started, owner: iosSeat)
        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(changes.last?.fields.sorted(), ["lastResult", "proof", "state", "waitingForUser"])
        let other = try await store.updateBoard(.init(id: "session:s2", kind: .session, stamp: .init(owner: .lead("crm"), session: "s2"), doing: "planning"))
        XCTAssertEqual(other.labels.project, "crm")
        let all = try await store.board(.init(owner: .hoot)), mine = try await store.board(.init(owner: iosSeat))
        let project = try await store.board(.init(owner: .lead("imatch"))), waiting = try await store.board(.init(waitingOnly: true))
        XCTAssertEqual(all.count, 2); XCTAssertEqual(mine.map(\.id), [id]); XCTAssertEqual(project.map(\.id), [id]); XCTAssertEqual(waiting.map(\.id), [id])
        _ = try await store.archiveBoardRow(id: id)
        let left = try await store.board(.init()), kept = try await store.board(.init(includeArchived: true))
        XCTAssertEqual(left.count, 1); XCTAssertEqual(kept.count, 2)
        await store.close()
    }

    /// #173: a session flips between working and idle all day. The board's history keeps a week and
    /// each row's newest change, never every flip for good.
    func testBoardHistoryKeepsAWeekAndEachRowsNewestChange() async throws {
        let data = try temp("data"), root = try temp("root").appendingPathComponent("Memory"), clock = DeckMemoryTestClock()
        var store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false, now: { clock.tick() })
        let busy = DeckMemoryStamp(owner: iosSeat, session: "s1"), quiet = DeckMemoryStamp(owner: iosSeat, session: "s2")
        _ = try await store.updateBoard(.init(id: "session:s2", kind: .session, stamp: quiet, doing: "planning"))
        _ = try await store.updateBoard(.init(id: "session:s2", kind: .session, stamp: quiet, doing: "waiting"))
        for flip in 0..<40 { _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: busy, doing: flip % 2 == 0 ? "working" : "idle")) }
        var changes = try await store.boardChanges(since: .distantPast, owner: nil)
        XCTAssertEqual(changes.count, 42, "Within the week every change is kept.")
        clock.jump(DeckMemoryStore.boardHistoryKept + 60)
        _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: busy, doing: "done"))
        changes = try await store.boardChanges(since: .distantPast, owner: nil)
        XCTAssertEqual(changes.filter { $0.row.id == "session:s1" }.map(\.row.doing), ["done"], "A busy row's changes older than a week go; its newest stays.")
        XCTAssertEqual(changes.filter { $0.row.id == "session:s2" }.count, 2, "A row that did not change is left until the next opening.")
        await store.close()
        store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false, now: { clock.tick() })
        changes = try await store.boardChanges(since: .distantPast, owner: nil)
        XCTAssertEqual(changes.map(\.row.doing), ["waiting", "done"], "Opening trims the quiet rows too, keeping each one's newest change.")
        await store.close()
    }

    // MARK: Diary

    func testTheDiaryIsWordForWordAndReadFromACursor() async throws {
        let (store, _, _) = try await open()
        let stamp = DeckMemoryStamp(owner: .hoot, session: "hoot", agent: "hoot")
        let exact = "  ok.  ship it —   and DON'T touch\nthe simulators  "
        let first = try await store.appendDiary(.init(stamp: stamp, role: .user, text: exact, conversation: "c1", externalID: "line-1"))
        XCTAssertEqual(first.text, exact)
        let again = try await store.appendDiary(.init(stamp: stamp, role: .user, text: "something else entirely", conversation: "c1", externalID: "line-1"))
        XCTAssertEqual(again.id, first.id); XCTAssertEqual(again.text, exact, "the same source line is stored once")
        let more = try await store.appendDiary([
            .init(stamp: stamp, role: .assistant, text: "Shipping now.", conversation: "c1", externalID: "line-2"),
            .init(stamp: stamp, role: .event, text: "turn ended", conversation: "c1"),
            .init(stamp: .init(owner: iosSeat, session: "s9"), role: .user, text: "unrelated", conversation: "s9")
        ])
        XCTAssertEqual(more.count, 3)
        let new = try await store.diary(.init(session: "hoot", after: first.id))
        XCTAssertEqual(new.map(\.text), ["Shipping now.", "turn ended"])
        let chat = try await store.diary(.init(conversation: "c1", roles: [.user, .assistant]))
        XCTAssertEqual(chat.map(\.text), [exact, "Shipping now."])
        let page = try await store.diary(.init(conversation: "c1", before: more[1].id, limit: 1))
        XCTAssertEqual(page.map(\.id), [more[0].id])
        let around = try await store.diary(around: more[0].id, before: 5, after: 5)
        XCTAssertEqual(around.map(\.id), [first.id, more[0].id, more[1].id])
        let head = try await store.diaryHead(session: "hoot"), top = try await store.diaryHead(session: nil)
        XCTAssertEqual(head, more[1].id); XCTAssertEqual(top, more[2].id)
        await store.close()
    }

    // MARK: Search

    func testSearchByWordsAndByMeaning() async throws {
        let (store, _, _) = try await open(embedder: DeckMemoryTestEmbedder())
        let release = try await store.addNote(.init(title: "TestFlight rule", body: "Deploy means a new build on TestFlight.", type: .decision, stamp: .hoot))
        let colour = try await store.addNote(.init(title: "Main buttons", body: "One blue main action per screen.", type: .preference, stamp: .hoot))
        let gone = try await store.addNote(.init(title: "Old colour rule", body: "Everything grey.", type: .preference, stamp: .hoot))
        _ = try await store.archiveNote(id: gone.id, reason: "wrong")
        let said = try await store.appendDiary(.init(stamp: .init(owner: .hoot, session: "hoot"), role: .user, text: "please publish it tonight", conversation: "c1"))
        _ = try await store.appendDiary(.init(stamp: .init(owner: iosSeat, session: "s1"), role: .user, text: "the login crash is back", conversation: "s1"))
        await store.finishEmbedding()

        let words = try await store.search(.init("testflight", mode: .words))
        XCTAssertEqual(words.hits.map(\.ref), [release.id]); XCTAssertFalse(words.usedMeaning); XCTAssertEqual(words.hits.first?.matchedBy, .words)
        XCTAssertEqual(words.hits.first?.kind, .note); XCTAssertEqual(words.hits.first?.path, release.path)
        let prefix = try await store.search(.init("butto", mode: .words))
        XCTAssertEqual(prefix.hits.map(\.ref), [colour.id], "the last word also matches longer words")
        let archived = try await store.search(.init("grey", mode: .words)), withArchive = try await store.search(.init("grey", includeArchived: true, mode: .words))
        XCTAssertTrue(archived.hits.isEmpty); XCTAssertEqual(withArchive.hits.map(\.ref), [gone.id]); XCTAssertEqual(withArchive.hits.first?.archived, true)
        let diary = try await store.search(.init("publish", kinds: [.diary], mode: .words))
        XCTAssertEqual(diary.hits.map(\.ref), [String(said.id)]); XCTAssertEqual(diary.hits.first?.labels.session, "hoot")
        let scoped = try await store.search(.init("login", owner: .hoot, mode: .words)), seat = try await store.search(.init("login", owner: iosSeat, mode: .words))
        XCTAssertTrue(scoped.hits.isEmpty); XCTAssertEqual(seat.hits.count, 1)
        let whole = try await store.search(.init("login", project: "imatch", mode: .words))
        XCTAssertEqual(whole.hits.count, 1)

        // "released" is in neither text; the meaning is.
        let meaning = try await store.search(.init("released", kinds: [.note, .diary], mode: .meaning))
        XCTAssertTrue(meaning.usedMeaning); XCTAssertNil(meaning.notice)
        XCTAssertEqual(Set(meaning.hits.map(\.ref)), [release.id, String(said.id)]); XCTAssertEqual(meaning.hits.first?.matchedBy, .meaning)
        let both = try await store.search(.init("design", kinds: [.note]))
        XCTAssertEqual(both.hits.map(\.ref), [colour.id], "no note says 'design'; one is about it")
        await store.close()
    }

    /// #45: weeks of diary messages never push a current note out of reach by meaning. The diary has its own window.
    func testAnOlderNoteIsStillFoundByMeaningAfterWeeksOfDiary() async throws {
        let (store, _, _) = try await open(embedder: DeckMemoryTestEmbedder())
        let release = try await store.addNote(.init(title: "TestFlight rule", body: "Deploy means a new build on TestFlight.", type: .decision, stamp: .hoot))
        await store.finishEmbedding()
        try await store.addDiaryVectors(DeckMemoryStore.meaningCandidates + 10, pointing: [0, 0, 1])   // weeks of talk about logins, all newer
        let found = try await store.search(.init("released", kinds: [.note, .diary], mode: .meaning))
        XCTAssertTrue(found.usedMeaning)
        XCTAssertEqual(found.hits.map(\.ref), [release.id], "Found by meaning although more diary pieces than one window came after it.")
        await store.close()
    }

    func testSearchFallsBackToWordsWhenMeaningIsNotAvailable() async throws {
        let (store, _, _) = try await open(embedder: nil)
        let note = try await store.addNote(.init(title: "TestFlight rule", body: "Deploy means a new build on TestFlight.", stamp: .hoot))
        let result = try await store.search(.init("testflight", mode: .meaning))
        XCTAssertFalse(result.usedMeaning); XCTAssertNotNil(result.notice); XCTAssertEqual(result.hits.map(\.ref), [note.id])
        await store.close()
    }

    // MARK: Files are the truth: outside edits

    func testAnOutsideEditIsPickedUpByTheIndex() async throws {
        let (store, root, _) = try await open()
        let note = try await store.addNote(.init(title: "Relay", body: "The relay is the network.", type: .decision, stamp: .hoot))
        let quiet = try await store.reindex()
        XCTAssertEqual(quiet.added + quiet.changed + quiet.missing, 0, "the app's own writes are not news")
        // 1. Someone edits the note in another app.
        try write(root, note.path, read(root, note.path).replacingOccurrences(of: "# Relay", with: "# Relay rule").replacingOccurrences(of: "is the network", with: "is the network, never Tailscale"))
        // 2. Someone drops a hand-written note in, with no labels at all.
        try write(root, "hoot/notes/by-hand.md", "# Coolify\n\nWe replace Coolify, we never integrate with it.\n")
        // 3. Someone edits the card and the playbook table.
        try write(root, "hoot/card.md", "# Hoot\n\n## Top rules\n- Short plain replies.\n")
        try write(root, "hoot/playbook.md", "# Playbook\n\n| Job | AI | Model | Effort | Permission | Standing instructions |\n|---|---|---|---|---|---|\n| design | claude | opus | high | acceptEdits | Show options first \\| never pick |\n| default | codex | | | | |\n\nKeep this line.\n")
        let report = try await store.reindex()
        XCTAssertEqual(report.added, 1); XCTAssertEqual(report.changed, 3); XCTAssertEqual(report.missing, 0)
        let edited = try await store.note(id: note.id)
        XCTAssertEqual(edited?.title, "Relay rule"); XCTAssertEqual(edited?.body, "The relay is the network, never Tailscale.")
        let found = try await store.search(.init("tailscale", mode: .words))
        XCTAssertEqual(found.hits.map(\.ref), [note.id])
        let dropped = try await store.search(.init("coolify", mode: .words))
        let byHand = try XCTUnwrap(dropped.hits.first)
        XCTAssertEqual(byHand.labels.owner, .hoot)
        let stamped = read(root, "hoot/notes/by-hand.md")
        XCTAssertTrue(stamped.contains("id: " + byHand.ref)); XCTAssertTrue(stamped.contains("seat: hoot")); XCTAssertTrue(stamped.contains("source: outside"))
        XCTAssertTrue(stamped.hasSuffix("# Coolify\n\nWe replace Coolify, we never integrate with it.\n"), "the person's text is untouched")
        let card = try await store.card(.hoot)
        XCTAssertEqual(card.topRules, ["- Short plain replies."])
        let playbook = try await store.playbook(.hoot)
        XCTAssertEqual(playbook.rows.map(\.jobKind), ["design", "default"]); XCTAssertEqual(playbook.rows[0].instructions, "Show options first | never pick")
        // Saving through the app keeps the text around the table.
        _ = try await store.savePlaybook(.hoot, rows: playbook.rows + [.init(jobKind: "research", ai: "gemini")])
        XCTAssertTrue(read(root, "hoot/playbook.md").contains("Keep this line.")); XCTAssertTrue(read(root, "hoot/playbook.md").contains("| research | gemini |"))
        // 4. A file removed outside the app is marked missing, never dropped, and comes back with the file.
        let kept = read(root, note.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent(note.path))
        let after = try await store.reindex()
        XCTAssertEqual(after.missing, 1)
        let listed = try await store.notes(.init(owner: .hoot)).map(\.id)
        XCTAssertFalse(listed.contains(note.id))
        try write(root, note.path, kept)
        _ = try await store.reindex()
        let returned = try await store.note(id: note.id)
        XCTAssertEqual(returned?.title, "Relay rule")
        await store.close()
    }

    // MARK: Hands and jobs (spec 3b)

    func testSeveralHandsOnOneSeatNeverOverwriteEachOther() async throws {
        let (store, root, _) = try await open()
        let one = DeckMemoryStamp(owner: iosSeat, session: "s1", hand: 1, job: "fix-login-crash")
        let two = DeckMemoryStamp(owner: iosSeat, session: "s2", hand: 2, job: "dark-mode")
        // The same title at the same moment from two hands: two files.
        let a = try await store.addNote(.init(title: "Lesson", body: "from hand one", type: .lesson, stamp: one))
        let b = try await store.addNote(.init(title: "Lesson", body: "from hand two", type: .lesson, stamp: two))
        XCTAssertNotEqual(a.path, b.path)
        let seatNotes = try await store.notes(.init(owner: iosSeat))
        XCTAssertEqual(seatNotes.count, 2, "both hands wrote into the one seat")
        let first = try await store.updateTopic(iosSeat, title: "Where we are", body: "Found the nil token.", stamp: one)
        let second = try await store.updateTopic(iosSeat, title: "Where we are", body: "Palette picked.", stamp: two)
        let shared = try await store.updateTopic(iosSeat, title: "Release train", body: "Next build Friday.", stamp: nil)
        XCTAssertEqual(first.id, "fix-login-crash"); XCTAssertEqual(second.id, "dark-mode"); XCTAssertEqual(shared.id, "release-train")
        XCTAssertEqual(first.job, "fix-login-crash"); XCTAssertNil(shared.job)
        XCTAssertTrue(exists(root, "projects/imatch/roles/the phone app's fix-login-crash.md")); XCTAssertTrue(exists(root, "projects/imatch/roles/the phone app's dark-mode.md"))
        let again = try await store.updateTopic(iosSeat, title: "Where we are", body: "Fix written, testing.", stamp: one)
        XCTAssertEqual(again.id, first.id); XCTAssertEqual(again.body, "Fix written, testing.")
        let other = try await store.topic(iosSeat, id: "dark-mode")
        XCTAssertEqual(other?.body, "Palette picked.", "hand one's update left hand two's topic alone")
        let mine = try await store.topics(iosSeat, job: "fix-login-crash", includeClosed: false).map(\.id)
        XCTAssertEqual(mine, ["fix-login-crash", "release-train"])
        let all = try await store.topics(iosSeat, includeClosed: false)
        XCTAssertEqual(all.count, 3)
        let brief = try await DeckMemoryBrief.opening(store, owner: iosSeat, session: "s1", job: "fix-login-crash")
        XCTAssertTrue(brief.text.contains("Fix written, testing.")); XCTAssertFalse(brief.text.contains("Palette picked."))
        _ = try await store.setTopic(iosSeat, id: "dark-mode", open: false)
        let open = try await store.topics(iosSeat, includeClosed: false), every = try await store.topics(iosSeat, includeClosed: true)
        XCTAssertEqual(open.count, 2); XCTAssertEqual(every.count, 3)
        await store.close()
    }

    func testAHelperSeatFoldsBackIntoItsParent() async throws {
        let (store, root, _) = try await open()
        let helper = DeckMemoryOwner.role(project: "imatch", role: "ios--helper-1")
        _ = try await store.ensureOwner(iosSeat, name: "iOS developer")
        let made = try await store.ensureOwner(helper, name: "Helper 1", parent: iosSeat)
        XCTAssertEqual(made.parent, iosSeat); XCTAssertTrue(made.isHelper)
        let note = try await store.addNote(.init(title: "Asset catalog trick", body: "Regenerate after renaming.", type: .lesson, stamp: .init(owner: helper, session: "h1", job: "icons")))
        let old = try await store.addNote(.init(title: "Wrong idea", body: "Delete the catalog.", stamp: .init(owner: helper)))
        _ = try await store.archiveNote(id: old.id, reason: "wrong")
        _ = try await store.updateTopic(helper, title: "Icons", body: "Half done.", stamp: .init(owner: helper, job: "icons"))
        _ = try await store.appendDiary(.init(stamp: .init(owner: helper, session: "h1"), role: .assistant, text: "icons regenerated"))
        let report = try await store.foldBack(helper)
        XCTAssertEqual(report.into, iosSeat); XCTAssertEqual(report.notes, 2); XCTAssertEqual(report.topics, 1)
        let afterFold = try await store.note(id: note.id)
        let moved = try XCTUnwrap(afterFold)
        XCTAssertEqual(moved.labels.owner, iosSeat); XCTAssertTrue(moved.path.hasPrefix("projects/imatch/roles/ios/notes/")); XCTAssertEqual(moved.labels.job, "icons")
        XCTAssertTrue(read(root, moved.path).contains("folded_from: role:imatch/ios--helper-1"))
        let stillArchived = try await store.note(id: old.id)
        XCTAssertEqual(stillArchived?.isArchived, true); XCTAssertEqual(stillArchived?.labels.owner, iosSeat)
        let topics = try await store.topics(iosSeat, job: "icons", includeClosed: false)
        XCTAssertEqual(topics.map(\.body), ["Half done."])
        XCTAssertFalse(exists(root, helper.folder), "the closed helper seat is no longer a seat")
        XCTAssertTrue(exists(root, "archive/" + helper.cardPath), "its own card is kept in the archive")
        let seats = try await store.owners().map(\.owner)
        XCTAssertFalse(seats.contains(helper)); XCTAssertTrue(seats.contains(iosSeat))
        let history = try await store.diary(.init(owner: helper))
        XCTAssertEqual(history.map(\.text), ["icons regenerated"], "the helper's diary stays as history")
        await store.close()
    }

    // MARK: Playbook

    func testThePlaybookRowForAJob() async throws {
        let (store, _, _) = try await open()
        _ = try await store.savePlaybook(.hoot, rows: [
            .init(jobKind: "design", ai: "claude", model: "opus", effort: "high", permission: "acceptEdits", instructions: "Options first."),
            .init(jobKind: "default", ai: "codex")
        ])
        let exact = try await store.playbookRow(.hoot, job: "Design"), partial = try await store.playbookRow(.hoot, job: "a design round for the Hoot page")
        let fallback = try await store.playbookRow(.hoot, job: "database fix")
        XCTAssertEqual(exact?.model, "opus"); XCTAssertEqual(partial?.jobKind, "design"); XCTAssertEqual(fallback?.ai, "codex")
        // A lead with no row of its own for the job uses Hoot's.
        _ = try await store.ensureOwner(.lead("crm"), name: "CRM lead")
        _ = try await store.savePlaybook(.lead("crm"), rows: [.init(jobKind: "migration", ai: "claude", model: "sonnet")])
        let own = try await store.playbookRow(.lead("crm"), job: "migration"), borrowed = try await store.playbookRow(.lead("crm"), job: "design")
        XCTAssertEqual(own?.model, "sonnet"); XCTAssertEqual(borrowed?.model, "opus")
        do { _ = try await store.playbook(iosSeat); XCTFail("an agent seat keeps no playbook") } catch let error as DeckMemoryError { XCTAssertEqual(error.code, .invalid) }
        await store.close()
    }

    // MARK: Import, migration, move

    func testImportKeepsANotesOwnValidFrom() async throws {
        let (store, root, _) = try await open()
        let seat = DeckMemoryOwner.role(project: "terminal-deck", role: "memory")
        let source = try temp("team-notes")
        try write(source, "dated.md", "---\ntype: result\nvalid_from: 2026-08-15\n---\nThe demo lives on its own box, never on his computers.\n")
        try write(source, "odd.md", "---\nvalid_from: last summer\n---\nA note whose own date is not a date.\n")
        try write(source, "plain.md", "A note with no labels at all.\n")
        let report = try await store.importFolder(source, into: seat, label: "team")
        XCTAssertTrue(report.verified, report.skipped.joined(separator: "; ")); XCTAssertEqual(report.imported, 3); XCTAssertTrue(report.skipped.isEmpty)
        let folder = "projects/terminal-deck/roles/memory/notes/imported/team/"
        // Its own date is kept exactly as written and is the date the note became true.
        let dated = read(root, folder + "dated.md")
        XCTAssertTrue(dated.contains("\nvalid_from: 2026-08-15\n"), dated); XCTAssertFalse(dated.contains("original_valid_from"), dated)
        let notes = try await store.notes(.init(owner: seat))
        let kept = try XCTUnwrap(notes.first { $0.path.hasSuffix("/dated.md") })
        XCTAssertEqual(DeckMemoryFiles.day(kept.validFrom, zone: TimeZone(identifier: "UTC")!), "2026-08-15")
        // A "date" that is not one stays beside the app's own; a note without one is dated by its file.
        let odd = read(root, folder + "odd.md")
        XCTAssertTrue(odd.contains("original_valid_from: last summer"), odd); XCTAssertFalse(odd.contains("\nvalid_from: last summer"), odd)
        XCTAssertTrue(read(root, folder + "plain.md").contains("valid_from: "))
        let again = try await store.importFolder(source, into: seat, label: "team")
        XCTAssertEqual(again.unchanged, 3); XCTAssertEqual(again.imported + again.updated, 0)
        await store.close()
    }

    func testTextsWrittenWithoutAModelGetTheirVectorsAtTheNextStart() async throws {
        let data = try temp("data"), root = try temp("root").appendingPathComponent("Memory")
        let model = DeckMemoryTestEmbedder()
        let first = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: model, watch: false)
        _ = try await first.addNote(.init(title: "Release rule", body: "Every release goes to TestFlight.", stamp: .hoot))
        await first.finishEmbedding(); await first.close()
        // One start without the model (it could not load): a note written then gets no vector.
        let wordsOnly = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false)
        let late = try await wordsOnly.addNote(.init(title: "Button colour", body: "Main buttons are blue.", stamp: .hoot))
        await wordsOnly.close()
        // The next start has the same model as before, so nothing is re-made for a model change; the late note
        // is queued anyway because it has no vector, and search by meaning finds it.
        let again = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: model, watch: false)
        let modelSetting = try await again.value("embedding.model", owner: nil)
        XCTAssertEqual(modelSetting, model.model)
        await again.finishEmbedding()
        let found = try await again.search(.init("grey design", mode: .meaning))
        XCTAssertTrue(found.hits.contains { $0.ref == late.id }, "hits: \(found.hits.map(\.title))")
        // Light: once every text has its vector, nothing more is queued.
        let queued = try await again.queueMissingVectors()
        XCTAssertEqual(queued, 0)
        await again.close()
    }

    func testImportCopiesAndNeverTouchesTheSource() async throws {
        let (store, root, _) = try await open()
        let source = try temp("claude-memory").appendingPathComponent("-Users-someone-ClaudeCRM/memory")
        try write(source, "MEMORY.md", "# Memory Index\n\n- [Deploy rule](feedback_deploy.md)\n")
        try write(source, "feedback_deploy.md", "---\nname: Deploy means TestFlight\ndescription: not a local build\ntype: feedback\n---\nDeploy means a release to TestFlight. See [[MEMORY]].\n")
        try write(source, "notes.txt", "not a note")
        func snapshot() throws -> [String: String] {
            var all: [String: String] = [:]
            for name in ["MEMORY.md", "feedback_deploy.md", "notes.txt"] {
                let file = source.appendingPathComponent(name)
                let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                all[name] = DeckMemoryFiles.hash(try Data(contentsOf: file)) + "@" + String(modified.timeIntervalSince1970)
            }
            return all
        }
        let before = try snapshot()
        let report = try await store.importFolder(source, into: .lead("crm"), label: "alex")
        XCTAssertEqual(report.imported, 2); XCTAssertEqual(report.updated, 0); XCTAssertTrue(report.verified); XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertEqual(report.folder, "projects/crm/lead/notes/imported/alex")
        XCTAssertEqual(try snapshot(), before, "the source is byte for byte and date for date as it was")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted(), ["MEMORY.md", "feedback_deploy.md", "notes.txt"])
        let copy = read(root, "projects/crm/lead/notes/imported/alex/feedback_deploy.md")
        XCTAssertTrue(copy.contains("name: Deploy means TestFlight")); XCTAssertTrue(copy.contains("type: feedback")); XCTAssertTrue(copy.contains("seat: lead:crm"))
        XCTAssertTrue(copy.contains("source: import")); XCTAssertTrue(copy.hasSuffix("Deploy means a release to TestFlight. See [[MEMORY]].\n"))
        let notes = try await store.notes(.init(owner: .lead("crm")))
        XCTAssertEqual(Set(notes.map(\.title)), ["Deploy means TestFlight", "Memory Index"])
        XCTAssertEqual(notes.first { $0.title == "Deploy means TestFlight" }?.type, "feedback")
        let again = try await store.importFolder(source, into: .lead("crm"), label: "alex")
        XCTAssertEqual(again.imported, 0); XCTAssertEqual(again.unchanged, 2); XCTAssertEqual(Set(again.noteIDs), Set(report.noteIDs))
        try write(source, "feedback_deploy.md", "---\nname: Deploy means TestFlight\ntype: feedback\n---\nDeploy means a release to TestFlight, and his host in the same batch.\n")
        let third = try await store.importFolder(source, into: .lead("crm"), label: "alex")
        XCTAssertEqual(third.updated, 1); XCTAssertEqual(third.unchanged, 1); XCTAssertEqual(Set(third.noteIDs), Set(report.noteIDs), "a refreshed copy keeps its id")
        let total = try await store.notes(.init(owner: .lead("crm")))
        XCTAssertEqual(total.count, 2)
        await store.close()
    }

    func testHootsOldMemoryComesInAsNotesAndTheOriginalStays() async throws {
        let (store, root, data) = try await open()
        let old = data.appendingPathComponent("hoot/memory")
        try write(old, "MEMORY.md", "# Memory\n\n- [[asad-prefers-short-replies]]\n")
        try write(old, "asad-prefers-short-replies.md", "---\nname: Short replies\ntype: feedback\n---\nShort, plain English. Always.\n")
        let original = try Data(contentsOf: old.appendingPathComponent("asad-prefers-short-replies.md"))
        let report = try await store.migrateHootMemory()
        XCTAssertEqual(report.imported, 2); XCTAssertTrue(report.verified); XCTAssertEqual(report.owner, .hoot)
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("asad-prefers-short-replies.md")), original)
        let copied = read(root, "hoot/notes/imported/hoot-memory/asad-prefers-short-replies.md")
        XCTAssertTrue(copied.contains("source: migration"))
        XCTAssertTrue(copied.contains("imported_from: the app's data: hoot/memory/asad-prefers-short-replies.md\n"))
        XCTAssertFalse(copied.contains(data.path), "no path of this copy's data folder is written into a label")
        let found = try await store.search(.init("plain english", owner: .hoot, mode: .words))
        XCTAssertEqual(found.hits.first?.title, "Short replies")
        let second = try await store.migrateHootMemory()
        XCTAssertEqual(second.imported, 0); XCTAssertEqual(second.unchanged, 2, "running it at every start adds nothing twice")
        await store.close()
    }

    func testMoveCopiesChecksSwitchesAndKeepsTheOldFolder() async throws {
        let (store, root, data) = try await open()
        let note = try await store.addNote(.init(title: "Before the move", body: "Still here after.", stamp: .hoot))
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "move the folder please"))
        let target = try temp("new-home").appendingPathComponent("Deck Memory")
        let occupied = try temp("occupied"); try write(occupied, "something.txt", "x")
        do { _ = try await store.move(to: occupied); XCTFail("a folder with things in it is refused") } catch let error as DeckMemoryError { XCTAssertEqual(error.code, .invalid) }
        let stillWorks = try await store.note(id: note.id)
        XCTAssertNotNil(stillWorks)
        let report = try await store.move(to: target)
        XCTAssertTrue(report.verified); XCTAssertEqual(report.from.path, root.path); XCTAssertEqual(report.to.path, target.path); XCTAssertGreaterThan(report.files, 8)
        let location = await store.location()
        XCTAssertEqual(location.root.path, target.path); XCTAssertEqual(location.previousRoots.map(\.path), [root.path]); XCTAssertFalse(location.isDefault)
        XCTAssertEqual(DeckMemoryPaths.root(dataRoot: data).path, target.path, "the next start opens the new folder")
        // The old folder is kept as it was, with one line saying where the memory went.
        XCTAssertTrue(exists(root, note.path)); XCTAssertTrue(exists(root, "memory.db")); XCTAssertTrue(read(root, "MOVED.md").contains(target.path))
        XCTAssertTrue(exists(target, note.path))
        let moved = try await store.note(id: note.id)
        XCTAssertEqual(moved?.body, "Still here after.")
        let diary = try await store.diary(.init(owner: .hoot))
        XCTAssertEqual(diary.map(\.text), ["move the folder please"])
        let later = try await store.addNote(.init(title: "After the move", body: "Written in the new place.", stamp: .hoot))
        XCTAssertTrue(exists(target, later.path)); XCTAssertFalse(exists(root, later.path))
        await store.close()
    }

    // MARK: What the research asked for (MEMORY-LESSONS)

    func testWhoReallyWroteItIsRecordedAndOnlyThePersonsWordsOutrankThePersons() async throws {
        let (store, root, _) = try await open()
        // In a session Hoot started, the "user" side is Hoot, not the person.
        let stamp = DeckMemoryStamp(owner: iosSeat, session: "s1")
        let fromHoot = try await store.appendDiary(.init(stamp: stamp, role: .user, text: "Fix the login crash first.", author: .orchestrator))
        let fromPerson = try await store.appendDiary(.init(stamp: stamp, role: .user, text: "No. Dark mode first, I said.", author: .person))
        let unsaid = try await store.appendDiary(.init(stamp: stamp, role: .user, text: "who typed this is not known"))
        XCTAssertEqual(fromHoot.author, .orchestrator); XCTAssertFalse(fromHoot.isFromThePerson)
        XCTAssertTrue(fromPerson.isFromThePerson); XCTAssertNil(unsaid.author); XCTAssertFalse(unsaid.isFromThePerson)
        let onlyPerson = try await store.diary(.init(session: "s1", authors: [.person]))
        XCTAssertEqual(onlyPerson.map(\.id), [fromPerson.id])
        // A note of the person's own words, with the rows it came from.
        let rule = try await store.addNote(.init(title: "Dark mode comes first", body: "Asad said: dark mode before the login crash.", type: .correction,
                                                 stamp: stamp, source: "helper", diaryRange: fromHoot.id...fromPerson.id, author: .person))
        XCTAssertEqual(rule.author, .person); XCTAssertTrue(rule.isFromThePerson); XCTAssertEqual(rule.diaryRange, fromHoot.id...fromPerson.id)
        XCTAssertTrue(read(root, rule.path).contains("author: person\n")); XCTAssertTrue(read(root, rule.path).contains("diary: \(fromHoot.id)-\(fromPerson.id)\n"))
        // An agent's words cannot replace it: both are kept and linked, and the caller is told why.
        let attempt = try await store.addNote(.init(title: "Login crash comes first", body: "The agent decided the crash is more urgent.", type: .decision,
                                                    stamp: stamp, supersedes: rule.id, source: "helper", author: .agent))
        XCTAssertNotNil(attempt.notReplaced); XCTAssertNil(attempt.supersedes)
        let standing = try await store.note(id: rule.id)
        XCTAssertEqual(standing?.status, .current)
        // The person's own later words can.
        let changed = try await store.addNote(.init(title: "Login crash comes first after all", body: "Asad said: do the crash first, it blocks the release.", type: .correction,
                                                    stamp: stamp, supersedes: rule.id, source: "helper", author: .person))
        XCTAssertNil(changed.notReplaced); XCTAssertEqual(changed.supersedes, rule.id)
        let replaced = try await store.note(id: rule.id)
        XCTAssertEqual(replaced?.status, .superseded)
        await store.close()
    }

    func testANoteHasTwoDatesAndReplacingIsJudgedByWhenItBecameTrue() async throws {
        let (store, root, _) = try await open()
        let day = { (n: Double) in Date(timeIntervalSince1970: 1_790_000_000 + n * 86_400) }
        // The real chain from his memory: 6 Oct, 9 Oct, 10 Oct.
        let first = try await store.addNote(.init(title: "Everything goes to Codex", body: "All work is given to Codex.", type: .decision, stamp: .hoot, source: "helper", validFrom: day(6)))
        let second = try await store.addNote(.init(title: "Codex for deep jobs, Claude lanes for the rest", body: "Codex takes one or two deep backend jobs.", type: .decision,
                                                   stamp: .hoot, supersedes: first.id, source: "helper", validFrom: day(9)))
        let third = try await store.addNote(.init(title: "All new work goes to Codex", body: "Every new job is a Codex chat.", type: .decision,
                                                  stamp: .hoot, supersedes: second.id, source: "helper", validFrom: day(10)))
        XCTAssertEqual(third.validFrom, day(10)); XCTAssertNotEqual(third.labels.date, day(10), "when it was written is the app's clock, not when it became true")
        XCTAssertTrue(read(root, third.path).contains("valid_from: " + DeckMemoryFiles.stamp(day(10))))
        let old = try await store.note(id: first.id), middle = try await store.note(id: second.id)
        XCTAssertEqual(old?.validUntil, day(9)); XCTAssertEqual(middle?.validUntil, day(10)); XCTAssertEqual(middle?.status, .superseded)
        // A search an AI asked for shows the current rule first and the replaced ones below it, labelled.
        let found = try await store.search(.init("Codex", kinds: [.note], mode: .words, includeReplaced: true))
        XCTAssertEqual(found.hits.first?.ref, third.id); XCTAssertNil(found.hits.first?.standing)
        XCTAssertEqual(Set(found.hits.dropFirst().map(\.ref)), [first.id, second.id])
        XCTAssertTrue(found.hits.dropFirst().allSatisfy { ($0.standing ?? "").hasPrefix("replaced") })
        let current = try await store.search(.init("Codex", kinds: [.note], mode: .words))
        XCTAssertEqual(current.hits.map(\.ref), [third.id], "text the app lays down by itself never includes replaced notes")
        // A note that arrives late but describes an EARLIER state does not replace the newer truth: it is kept as history.
        let late = try await store.addNote(.init(title: "Codex is paused", body: "Codex hit its limit and is paused.", type: .decision,
                                                 stamp: .hoot, supersedes: third.id, source: "helper", validFrom: day(8)))
        XCTAssertNotNil(late.notReplaced); XCTAssertEqual(late.status, .history)
        let stillCurrent = try await store.note(id: third.id)
        XCTAssertEqual(stillCurrent?.status, .current)
        // By date: only what became true on or after 9 Oct.
        let since = try await store.search(.init("Codex", kinds: [.note], includeArchived: true, mode: .words, since: day(9)))
        XCTAssertEqual(Set(since.hits.map(\.ref)), [second.id, third.id])
        let until = try await store.search(.init("Codex", kinds: [.note], includeArchived: true, mode: .words, until: day(7)))
        XCTAssertEqual(until.hits.map(\.ref), [first.id])
        await store.close()
    }

    func testTheSameTextIsStoredOnceAndSecretsNeverReachAFile() async throws {
        let (store, root, _) = try await open()
        let one = try await store.addNote(.init(title: "Relay", body: "The relay is the network.", stamp: .hoot))
        let again = try await store.addNote(.init(title: "relay", body: "The   relay is the\nnetwork.", stamp: .hoot))
        XCTAssertEqual(again.duplicateOf, one.id); XCTAssertEqual(again.id, one.id)
        let count = try await store.notes(.init(owner: .hoot)).count
        XCTAssertEqual(count, 1)
        let elsewhere = try await store.addNote(.init(title: "Relay", body: "The relay is the network.", stamp: .init(owner: iosSeat)))
        XCTAssertNil(elsewhere.duplicateOf, "another seat's memory is its own")
        let secret = try await store.addNote(.init(title: "Server access", body: "Log in with password: hunter2secret9 and the key ghp_abcdefghijklmnopqrstuvwxyz0123456789.", stamp: .hoot))
        let text = read(root, secret.path)
        XCTAssertFalse(text.contains("hunter2secret9")); XCTAssertFalse(text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertTrue(text.contains(DeckMemoryRedaction.marker)); XCTAssertTrue(text.contains("Log in with password:"))
        // The diary stays word for word; what leaves it for anyone but Hoot is cleaned, and private parts are never indexed.
        let said = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "token=abc123def456ghi <private>my bank pin is 4321</private> ship it", author: .person))
        XCTAssertTrue(said.text.contains("abc123def456ghi")); XCTAssertTrue(said.text.contains("4321"))
        let shared = DeckMemoryRedaction.forSharing(said.text)
        XCTAssertFalse(shared.contains("abc123def456ghi")); XCTAssertFalse(shared.contains("4321")); XCTAssertTrue(shared.contains("ship it"))
        let hidden = try await store.search(.init("bank pin", kinds: [.diary], mode: .words))
        XCTAssertTrue(hidden.hits.isEmpty)
        await store.close()
    }

    // U17 (#303, #662): the memory filter is the app's one rule, so npm and GitLab keys never reach a file or a share.
    func testNpmAndGitLabKeysAreHiddenBeforeStorageAndSharing() async throws {
        let (store, root, _) = try await open()
        let npm = "npm_" + String(repeating: "Ab3", count: 12), gitlab = "glpat-" + String(repeating: "xY7_", count: 5)
        let body = "Publish with \(npm); mirror with \(gitlab)."
        let saved = try await store.addNote(.init(title: "Registry keys", body: body, stamp: .hoot))
        let text = read(root, saved.path)
        XCTAssertFalse(text.contains(npm)); XCTAssertFalse(text.contains(gitlab)); XCTAssertTrue(text.contains(DeckMemoryRedaction.marker))
        let shared = DeckMemoryRedaction.forSharing(body)
        XCTAssertFalse(shared.contains(npm)); XCTAssertFalse(shared.contains(gitlab)); XCTAssertTrue(shared.contains("Publish with"))
        await store.close()
    }

    func testAnExactWordHitCanComeFirstWithNoMeaningMatchAtAll() async throws {
        let (store, _, _) = try await open(embedder: DeckMemoryTestEmbedder())
        // "build 4127" is found only by its words; the embedder knows nothing about it.
        let exact = try await store.addNote(.init(title: "Installed build", body: "Build 4127 is on his phone.", type: .result, stamp: .hoot))
        let about = try await store.addNote(.init(title: "Release habit", body: "We publish through TestFlight.", type: .decision, stamp: .hoot))
        await store.finishEmbedding()
        let byNumber = try await store.search(.init("4127", kinds: [.note]))
        XCTAssertEqual(byNumber.hits.first?.ref, exact.id); XCTAssertEqual(byNumber.hits.first?.matchedBy, .words)
        XCTAssertTrue(byNumber.usedMeaning, "meaning took part and found nothing; the word hit still stands alone")
        // Found by both lists: it outranks one found by meaning alone.
        let both = try await store.search(.init("testflight release", kinds: [.note]))
        XCTAssertEqual(both.hits.first?.ref, about.id); XCTAssertEqual(both.hits.first?.matchedBy, .both)
        await store.close()
    }

    func testTheOpeningTextIsFittedToEachAppsLimitAndSaysWhatItLeftOut() async throws {
        let (store, _, _) = try await open()
        _ = try await store.ensureOwner(iosSeat, name: "iOS developer")
        _ = try await store.saveCard(iosSeat, text: "# iOS developer\n\n## Top rules\n- Never touch a simulator you did not boot.\n\n## Notes\n" + String(repeating: "Own detail line.\n", count: 40))
        _ = try await store.saveCard(.project("imatch"), text: "# iMatch\n\n" + String(repeating: "Project detail line.\n", count: 60))
        for index in 1...6 { _ = try await store.updateTopic(iosSeat, title: "Topic \(index)", body: String(repeating: "Where topic \(index) stands. ", count: 30), stamp: nil) }
        for index in 1...20 {
            _ = try await store.updateBoard(.init(id: "session:b\(index)", kind: .session, stamp: .init(owner: iosSeat, session: "b\(index)"),
                                                  title: "Job \(index)", doing: String(repeating: "working ", count: 12), lastResult: "Did part \(index)."))
        }
        let whole = try await DeckMemoryBrief.opening(store, owner: iosSeat)
        XCTAssertTrue(whole.fits); XCTAssertTrue(whole.leftOut.isEmpty); XCTAssertGreaterThan(whole.text.count, DeckMemoryBrief.Limit.claudeCodeHook)
        let claude = try await DeckMemoryBrief.opening(store, owner: iosSeat, limit: DeckMemoryBrief.Limit.claudeCodeHook)
        XCTAssertLessThanOrEqual(claude.text.count, DeckMemoryBrief.Limit.claudeCodeHook); XCTAssertTrue(claude.fits)
        XCTAssertFalse(claude.leftOut.isEmpty, "something had to go, and it says what")
        XCTAssertTrue(claude.text.contains("Not shown here")); XCTAssertTrue(claude.text.contains("memory.board.read"))
        XCTAssertTrue(claude.text.contains("- Never touch a simulator you did not boot."), "the top rules are never left out")
        XCTAssertTrue(claude.text.contains("Report in three lines") || claude.text.contains("## Top rules"), "the shared template card stays")
        // Whole items only: every topic that is shown is shown complete.
        for index in 1...6 where claude.text.contains("### Topic \(index)\n") {
            XCTAssertTrue(claude.text.contains(String(repeating: "Where topic \(index) stands. ", count: 30).trimmingCharacters(in: .whitespaces)))
        }
        let tight = try await DeckMemoryBrief.opening(store, owner: iosSeat, limit: 2_600)
        XCTAssertTrue(tight.leftOut.contains("the project's card")); XCTAssertTrue(tight.text.contains("- Never touch a simulator you did not boot."))
        // A limit nothing can meet is reported, not obeyed by cutting.
        let impossible = try await DeckMemoryBrief.opening(store, owner: iosSeat, limit: 300)
        XCTAssertFalse(impossible.fits); XCTAssertGreaterThan(impossible.text.count, 300)
        let lines = try await DeckMemoryBrief.messageLines(store, owner: iosSeat, since: Date(timeIntervalSince1970: 0), limit: DeckMemoryBrief.Limit.messageLines)
        XCTAssertLessThanOrEqual(lines.text.count, DeckMemoryBrief.Limit.messageLines); XCTAssertTrue(lines.text.contains("Top rules:"))
        XCTAssertFalse(lines.leftOut.isEmpty); XCTAssertTrue(lines.text.contains("memory.board.read"))
        await store.close()
    }

    /// The real on-device model (Apple's NaturalLanguage sentence embedding), when this Mac has it.
    func testTheOnDeviceModelFindsAParaphraseWithNoSharedWords() async throws {
        let model = DeckMemoryNLEmbedder.shared
        try XCTSkipUnless(model.isAvailable, "This Mac has no on-device sentence model; search then uses words only.")
        let (store, _, _) = try await open(embedder: model)
        let money = try await store.addNote(.init(title: "Invoices", body: "The customer has not paid the bill for September yet.", type: .openItem, stamp: .hoot))
        _ = try await store.addNote(.init(title: "Simulators", body: "Never shut down a simulator another lane booted.", type: .preference, stamp: .hoot))
        _ = try await store.addNote(.init(title: "Buttons", body: "One blue main action per screen.", type: .preference, stamp: .hoot))
        await store.finishEmbedding()
        // None of the query's words are in the note.
        let found = try await store.search(.init("money we are still owed", kinds: [.note], mode: .meaning))
        XCTAssertTrue(found.usedMeaning); XCTAssertNil(found.notice)
        XCTAssertEqual(found.hits.first?.ref, money.id, "hits: \(found.hits.map { $0.title + " " + String(format: "%.2f", $0.score) })")
        await store.close()
    }

    func testAFolderThatAlreadyHoldsOtherThingsIsNeverTakenOver() throws {
        let home = try temp("home")
        let data = home.appendingPathComponent("Library/Application Support/terminaldeck")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let wanted = DeckMemoryPaths.defaultRoot(dataRoot: data, home: home)
        XCTAssertEqual(wanted.lastPathComponent, "Terminal Deck Memory")
        XCTAssertTrue(DeckMemoryPaths.isFreeOrMemory(wanted), "nothing there yet")
        try write(wanted, "install.sh", "#!/bin/sh")
        XCTAssertFalse(DeckMemoryPaths.isFreeOrMemory(wanted), "someone else's files")
        try write(wanted, "memory.db", "")
        XCTAssertTrue(DeckMemoryPaths.isFreeOrMemory(wanted), "a memory folder is ours to open again")
        // The data folder the app was started with decides the place; the name never changes.
        let started = DeckMemoryPaths.appDataRoot(environment: ["TD_NATIVE_DATA_DIR": home.appendingPathComponent("elsewhere/data").path], home: home)
        XCTAssertEqual(DeckMemoryPaths.defaultRoot(dataRoot: started, home: home).path, home.appendingPathComponent("elsewhere/data/Terminal Deck Memory").path)
        XCTAssertEqual(DeckMemoryPaths.defaultRoot(dataRoot: DeckMemoryPaths.appDataRoot(environment: [:], home: home), home: home).path, wanted.path)
    }

    func testAnOlderInstallsHomeFolderMovesIntoTheAppsDataFolderOnceAndOnlyWhenSafe() async throws {
        let home = try temp("older-install")
        let data = home.appendingPathComponent("Library/Application Support/terminaldeck")
        let old = home.appendingPathComponent("Terminal Deck Memory"), new = data.appendingPathComponent("Terminal Deck Memory")
        // Nothing in the old place: nothing to do.
        XCTAssertNil(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: data, home: home))
        // A home folder of that name that is not a memory folder is never taken.
        try write(old, "mine.txt", "not memory")
        XCTAssertNil(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: data, home: home))
        XCTAssertEqual(read(old, "mine.txt"), "not memory"); XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        try FileManager.default.removeItem(at: old)
        // The memory an older install kept in the home folder.
        let before = try await DeckMemoryStore.open(root: old, dataRoot: nil, embedder: nil, watch: false)
        let note = try await before.addNote(.init(title: "Made before the move", body: "Still here after it.", stamp: .hoot))
        await before.close()
        try write(old, "seats/hoot/extra/deep.md", "a file further down")
        // Another copy of the app (its own data folder) never touches the installed app's old folder.
        XCTAssertNil(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: home.appendingPathComponent("other-copy"), home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("memory.db").path))
        // Moved: every file copied and compared, then the old folder removed; one log line.
        let line = try XCTUnwrap(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: data, home: home))
        XCTAssertTrue(line.hasPrefix("Memory moved into the app's data folder"), line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for file in ["memory.db", "START-HERE.md", "CLAUDE.md", "AGENTS.md", "GEMINI.md", "seats/hoot/extra/deep.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent(file).path), file)
        }
        // Done once: the next start has nothing to do, and opens the moved folder with everything in it.
        XCTAssertNil(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: data, home: home))
        let after = try await DeckMemoryStore.open(root: DeckMemoryPaths.root(dataRoot: data), dataRoot: data, embedder: nil, watch: false)
        let location = await after.location()
        XCTAssertEqual(location.root.path, new.path)
        let kept = try await after.note(id: note.id)
        XCTAssertEqual(kept?.body, "Still here after it.")
        XCTAssertFalse(read(new, "START-HERE.md").isEmpty)
        await after.close()
        // An old folder that shows up again while the new place already holds memory is left exactly as it is.
        try write(old, "memory.db", "older")
        let left = try XCTUnwrap(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: data, home: home))
        XCTAssertTrue(left.contains("left the older folder as it is"), left)
        XCTAssertEqual(read(old, "memory.db"), "older")
        // A new place that holds someone else's files is never filled: the memory goes beside it under the first free name.
        try FileManager.default.removeItem(at: new)
        try write(new, "theirs.txt", "not memory")
        try FileManager.default.removeItem(at: old)
        let again = try await DeckMemoryStore.open(root: old, dataRoot: nil, embedder: nil, watch: false)
        await again.close()
        let beside = try XCTUnwrap(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: data, home: home))
        XCTAssertTrue(beside.contains("Terminal Deck Memory 2"), beside)
        XCTAssertEqual(read(new, "theirs.txt"), "not memory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Terminal Deck Memory 2/memory.db").path))
        XCTAssertEqual(DeckMemoryPaths.root(dataRoot: data).lastPathComponent, "Terminal Deck Memory 2")
        try write(old, "memory.db", "older")
        // A folder the person chose with Move… is never second-guessed.
        try FileManager.default.removeItem(at: new)
        try DeckMemoryPaths.writePointer(.init(root: home.appendingPathComponent("Picked").path, previous: []), dataRoot: data)
        XCTAssertNil(DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: data, home: home))
        XCTAssertEqual(read(old, "memory.db"), "older")
    }

    func testACopyWithItsOwnDataFolderKeepsItsMemoryInsideItAndCanStillMoveIt() async throws {
        // No folder is named: the store finds its place from the data folder alone, as the app does.
        let data = try temp("own-data")
        let store = try await DeckMemoryStore.open(dataRoot: data, embedder: nil, watch: false)
        let first = await store.location()
        XCTAssertEqual(first.root.path, data.appendingPathComponent("Terminal Deck Memory").path); XCTAssertTrue(first.isDefault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.root.appendingPathComponent("START-HERE.md").path))
        let note = try await store.addNote(.init(title: "Kept through the move", body: "Still here.", stamp: .hoot))
        let elsewhere = try temp("picked").appendingPathComponent("My Memory")
        let report = try await store.move(to: elsewhere)
        XCTAssertTrue(report.verified)
        let second = await store.location()
        XCTAssertEqual(second.root.path, elsewhere.path); XCTAssertFalse(second.isDefault); XCTAssertEqual(second.defaultRoot.path, first.root.path)
        let kept = try await store.note(id: note.id)
        XCTAssertEqual(kept?.body, "Still here.")
        await store.close()
        // The next start of the same copy opens the moved folder.
        let again = try await DeckMemoryStore.open(dataRoot: data, embedder: nil, watch: false)
        let third = await again.location()
        XCTAssertEqual(third.root.path, elsewhere.path)
        let stillThere = try await again.note(id: note.id)
        XCTAssertNotNil(stillThere)
        await again.close()
    }

    // MARK: Rewind

    func testRewindSetsThePartAsideKeepsItAsHistoryAndCanBeUndone() async throws {
        let (store, root, _) = try await open()
        let stamp = DeckMemoryStamp(owner: .hoot, session: "hoot", agent: "hoot")
        func say(_ role: DeckMemoryDiaryRole, _ text: String) async throws -> DeckMemoryDiaryEntry {
            try await store.appendDiary(.init(stamp: stamp, role: role, text: text, conversation: "c1", author: role == .user ? .person : .orchestrator))
        }
        let q1 = try await say(.user, "Which colour for the main buttons?")
        let a1 = try await say(.assistant, "Blue, one per screen.")
        // Before the part that will be rewound: a topic and a note that rests on the early rows.
        _ = try await store.updateTopic(.hoot, title: "Button colours", body: "Main buttons are blue.", stamp: stamp)
        let early = try await store.addNote(.init(title: "Main buttons are blue", body: "One blue main action per screen.", type: .decision, stamp: stamp, source: "helper", diaryRange: q1.id...a1.id, author: .person))
        let q2 = try await say(.user, "Actually make everything grey and flat.")
        let a2 = try await say(.assistant, "Done: everything is grey now.")
        // From the part that will be rewound: a note resting only on it, one resting on both parts, a topic update, a new topic.
        let late = try await store.addNote(.init(title: "Everything is grey", body: "The whole app is grey and flat.", type: .decision, stamp: stamp, source: "helper", diaryRange: q2.id...a2.id, author: .person))
        let both = try await store.addNote(.init(title: "Colour talk", body: "Colours were discussed twice.", type: .note, stamp: stamp, source: "helper", diaryRange: a1.id...a2.id))
        let unlinked = try await store.addNote(.init(title: "No record of its rows", body: "Kept: the store does not guess.", stamp: stamp))
        _ = try await store.updateTopic(.hoot, title: "Button colours", body: "Everything is grey and flat.", stamp: stamp)
        _ = try await store.updateTopic(.hoot, title: "Grey sweep", body: "Sweeping every page to grey.", stamp: stamp)
        _ = try await store.appendDiary(.init(stamp: .init(owner: .hoot, session: "other"), role: .user, text: "another conversation, untouched", conversation: "c2"))

        // He rewinds to "Blue, one per screen."
        let rewind = try await store.markRewound(owner: .hoot, conversation: "c1", after: a1.id)
        XCTAssertEqual(rewind.rows, 2); XCTAssertEqual(rewind.after, a1.id); XCTAssertEqual(rewind.notes, [late.id])
        XCTAssertEqual(Set(rewind.topics), ["grey-sweep", "button-colours"])
        // The live conversation ends at the chosen message; the rest is still in the diary, marked.
        let live = try await store.diary(.init(conversation: "c1"))
        XCTAssertEqual(live.map(\.id), [q1.id, a1.id])
        let history = try await store.diary(.init(conversation: "c1", includeRewound: true))
        XCTAssertEqual(history.map(\.id), [q1.id, a1.id, q2.id, a2.id])
        XCTAssertEqual(history.map(\.isRewound), [false, false, true, true]); XCTAssertEqual(history[2].text, "Actually make everything grey and flat.")
        let elsewhere = try await store.diary(.init(conversation: "c2"))
        XCTAssertEqual(elsewhere.count, 1)
        // Search still finds it, and says what it is.
        let found = try await store.search(.init("grey flat", kinds: [.diary], mode: .words))
        XCTAssertFalse(found.hits.isEmpty); XCTAssertTrue(found.hits.allSatisfy { ($0.standing ?? "").hasPrefix("rewound on") })
        // Notes: only the one resting ONLY on rewound rows is set aside; it is archived, not removed.
        let lateNow = try await store.note(id: late.id), earlyNow = try await store.note(id: early.id)
        let bothNow = try await store.note(id: both.id), unlinkedNow = try await store.note(id: unlinked.id)
        XCTAssertEqual(lateNow?.status, .rewound); XCTAssertEqual(lateNow?.archiveReason, "rewound"); XCTAssertTrue(exists(root, "archive/" + late.path))
        XCTAssertEqual(earlyNow?.status, .current); XCTAssertEqual(bothNow?.status, .current); XCTAssertEqual(unlinkedNow?.status, .current)
        // Topics: the updated one has its earlier text back; the one begun in the rewound part is set aside.
        let colours = try await store.topic(.hoot, id: "button-colours"), sweep = try await store.topic(.hoot, id: "grey-sweep")
        XCTAssertEqual(colours?.body, "Main buttons are blue."); XCTAssertEqual(colours?.open, true)
        XCTAssertEqual(sweep?.open, false); XCTAssertEqual(sweep?.body, "Sweeping every page to grey.")
        let open = try await store.topics(.hoot, includeClosed: false).map(\.id)
        XCTAssertEqual(open, ["button-colours"])
        let listed = try await store.rewinds(owner: .hoot, conversation: "c1")
        XCTAssertEqual(listed.map(\.id), [rewind.id]); XCTAssertFalse(listed[0].isUndone)
        do { _ = try await store.markRewound(owner: .hoot, conversation: "c1", after: a1.id); XCTFail("nothing is left after that message") }
        catch let error as DeckMemoryError { XCTAssertEqual(error.code, .notFound) }

        // Undo: everything is as it was before the rewind.
        let undone = try await store.undoRewind(id: rewind.id)
        XCTAssertTrue(undone.isUndone)
        let back = try await store.diary(.init(conversation: "c1"))
        XCTAssertEqual(back.map(\.id), [q1.id, a1.id, q2.id, a2.id]); XCTAssertTrue(back.allSatisfy { !$0.isRewound })
        let lateBack = try await store.note(id: late.id)
        XCTAssertEqual(lateBack?.status, .current); XCTAssertEqual(lateBack?.path, late.path); XCTAssertTrue(exists(root, late.path))
        let coloursBack = try await store.topic(.hoot, id: "button-colours"), sweepBack = try await store.topic(.hoot, id: "grey-sweep")
        XCTAssertEqual(coloursBack?.body, "Everything is grey and flat."); XCTAssertEqual(sweepBack?.open, true)

        // Rewind again, then the conversation goes on: the old part can no longer be put back into it.
        let second = try await store.markRewound(owner: .hoot, conversation: "c1", after: a1.id)
        _ = try await say(.user, "Keep them blue. What about the icons?")
        do { _ = try await store.undoRewind(id: second.id); XCTFail("the conversation has gone on") }
        catch let error as DeckMemoryError { XCTAssertEqual(error.code, .conflict) }
        let onward = try await store.diary(.init(conversation: "c1"))
        XCTAssertEqual(onward.map(\.text), ["Which colour for the main buttons?", "Blue, one per screen.", "Keep them blue. What about the icons?"])
        let kept = try await store.diary(.init(conversation: "c1", includeRewound: true))
        XCTAssertEqual(kept.count, 5, "nothing was removed from the diary")
        await store.close()
    }

    // MARK: Handoffs

    func testHandoffsAreKeptWithTheirTopicListedNewestFirstAndNeverDeleted() async throws {
        let (store, root, _) = try await open()
        let stamp = DeckMemoryStamp(owner: .hoot, session: "hoot", agent: "hoot")
        _ = try await store.updateTopic(.hoot, title: "Deck Memory build", body: "Store is in; tools next.", stamp: stamp)
        let stream = store.changes()
        let first = try await store.saveHandoff(.init(title: "Deck Memory: where it stands", markdown: "# Goal\nLong-term memory for every seat.\n\n## What is left\nThe tools.",
                                                      stamp: stamp, topic: "Deck Memory build", author: .orchestrator))
        XCTAssertEqual(first.topic, "deck-memory-build", "found by the topic's title, kept under its id")
        XCTAssertTrue(first.path.hasPrefix("hoot/topics/deck-memory-build/handoffs/")); XCTAssertTrue(exists(root, first.path))
        XCTAssertEqual(first.author, .orchestrator); XCTAssertEqual(first.labels.owner, .hoot); XCTAssertEqual(first.labels.type, "handoff")
        XCTAssertTrue(first.markdown.hasPrefix("# Goal")); XCTAssertEqual(first.title, "Deck Memory: where it stands")
        let text = read(root, first.path)
        for line in ["id: " + first.id, "type: handoff", "seat: hoot", "topic: deck-memory-build", "author: orchestrator", "title: Deck Memory: where it stands"] {
            XCTAssertTrue(text.contains(line + "\n"), line)
        }
        // The change carries the id, so a panel can open on it.
        var seen: DeckMemoryChange?
        for await change in stream { seen = change; break }
        XCTAssertEqual(seen?.area, .topics); XCTAssertEqual(seen?.ref, "handoff:" + first.id); XCTAssertEqual(seen?.owner, .hoot)
        let second = try await store.saveHandoff(.init(title: "Deck Memory: after the tools", markdown: "## Where we are now\nTools are in.", stamp: stamp, topic: "deck-memory-build"))
        let whole = try await store.saveHandoff(.init(title: "Everything so far", markdown: "## Goal\nThe whole conversation.", stamp: stamp, topic: nil))
        XCTAssertNil(whole.topic); XCTAssertTrue(whole.path.hasPrefix("hoot/handoffs/"))
        let listed = try await store.handoffs(.hoot, topic: "deck-memory-build", includeArchived: false).map(\.id)
        XCTAssertEqual(listed, [second.id, first.id], "newest first")
        let conversation = try await store.handoffs(.hoot, topic: nil, includeArchived: false).map(\.id)
        XCTAssertEqual(conversation, [whole.id])
        let all = try await store.allHandoffs(.hoot, includeArchived: false)
        XCTAssertEqual(all.count, 3)
        let other = try await store.handoffs(iosSeat, topic: "deck-memory-build", includeArchived: false)
        XCTAssertTrue(other.isEmpty, "another seat's handoffs are its own")
        // Read one, and find it by its words; a handoff does not pose as a topic.
        let one = try await store.handoff(id: first.id)
        XCTAssertEqual(one?.markdown, first.markdown)
        let found = try await store.search(.init("long-term memory seat", mode: .words))
        let hit = try XCTUnwrap(found.hits.first { $0.ref.hasSuffix("#handoff:" + first.id) })
        XCTAssertEqual(hit.title, "Handoff: Deck Memory: where it stands"); XCTAssertEqual(hit.path, first.path)
        let topics = try await store.topics(.hoot, includeClosed: true).map(\.id)
        XCTAssertEqual(topics, ["deck-memory-build"])
        // The person edits it: the earlier text is kept.
        let edited = try await store.updateHandoff(id: first.id, title: nil, markdown: "# Goal\nLong-term memory for every seat, and it survives a new hire.")
        XCTAssertEqual(edited.author, .person); XCTAssertTrue(edited.markdown.contains("survives a new hire"))
        XCTAssertFalse(DeckMemoryFiles.markdown(under: root.appendingPathComponent("archive/versions/hoot/topics/deck-memory-build/handoffs")).isEmpty)
        // Archived, not removed; and back again.
        let away = try await store.archiveHandoff(id: second.id, reason: "out of date")
        XCTAssertTrue(away.isArchived); XCTAssertEqual(away.path, "archive/" + second.path); XCTAssertTrue(exists(root, "archive/" + second.path))
        let left = try await store.handoffs(.hoot, topic: "deck-memory-build", includeArchived: false).map(\.id)
        let kept = try await store.handoffs(.hoot, topic: "deck-memory-build", includeArchived: true).map(\.id)
        XCTAssertEqual(left, [first.id]); XCTAssertEqual(kept, [second.id, first.id])
        let back = try await store.restoreHandoff(id: second.id)
        XCTAssertFalse(back.isArchived); XCTAssertEqual(back.path, second.path)
        // A handoff written into the folder by hand is picked up, and one removed outside the app is only marked missing.
        try write(root, "hoot/topics/deck-memory-build/handoffs/by-hand.md", "# Written outside\n\nPicked up on the next look.\n")
        let report = try await store.reindex()
        XCTAssertEqual(report.added, 1); XCTAssertEqual(report.changed, 0)
        let grown = try await store.handoffs(.hoot, topic: "deck-memory-build", includeArchived: false)
        XCTAssertEqual(grown.count, 3); XCTAssertTrue(grown.contains { $0.title == "Written outside" })
        await store.close()
    }

    // MARK: Cleaning up by hand while the app is closed (the rules given to M2 for the real memory)

    func testAnOfflineCleanUpIsFollowedAtTheNextStartAndNothingIsDropped() async throws {
        let data = try temp("data"), root = try temp("root").appendingPathComponent("Memory")
        let clock = DeckMemoryTestClock()
        var store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false, now: { clock.tick() })
        let scratch = DeckMemoryOwner.role(project: nil, role: "mt-builder-role")
        _ = try await store.ensureOwner(scratch, name: "Builder test")
        let testNote = try await store.addNote(.init(title: "Made by a test", body: "Not real.", stamp: .init(owner: scratch)))
        let hootTest = try await store.addNote(.init(title: "Test note in Hoot's seat", body: "Also not real.", stamp: .hoot))
        let real = try await store.addNote(.init(title: "A real note", body: "Keep me.", stamp: .hoot))
        _ = try await store.updateTopic(scratch, title: "Scratch topic", body: "Test.", stamp: nil)
        _ = try await store.updateTopic(.hoot, title: "Test topic", body: "Test.", stamp: nil)
        let row = try await store.appendDiary(.init(stamp: .init(owner: scratch, session: "t1"), role: .user, text: "typed by a builder's test", author: .orchestrator))
        _ = try await store.updateBoard(.init(id: "session:t1", kind: .session, stamp: .init(owner: scratch, session: "t1"), title: "Test session", doing: "testing"))
        await store.close()

        // 1. One note of a real seat: labels added, file moved to archive/ at the same path.
        func archiveByHand(_ path: String) throws {
            var text = read(root, path)
            text = text.replacingOccurrences(of: "---\n# ", with: "archived: 2026-10-11T07:40:00Z\narchive_reason: test\nstatus: archived\n---\n# ")
            try write(root, "archive/" + path, text)
            try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }
        try archiveByHand(hootTest.path)
        // 2. A topic closed in its file.
        try write(root, "hoot/topics/test-topic.md", read(root, "hoot/topics/test-topic.md").replacingOccurrences(of: "status: open", with: "status: closed"))
        // 3. The whole scratch seat moved into archive/, its note labelled first.
        try write(root, testNote.path, read(root, testNote.path).replacingOccurrences(of: "---\n# ", with: "archived: 2026-10-11T07:40:00Z\narchive_reason: test\nstatus: archived\n---\n# "))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("archive/roles"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("roles/mt-builder-role"), to: root.appendingPathComponent("archive/roles/mt-builder-role"))
        // 4. The database, with the app closed: authors and the board.
        let database = try DeckMemoryDatabase(path: root.appendingPathComponent("memory.db").path)
        try database.transaction {
            try database.run("UPDATE diary SET author = 'tool', meta = json_set(meta, '$.source', 'dev-test') WHERE id = ?", [.int(row.id)])
            try database.run("UPDATE board SET archived = CAST(strftime('%s','now') AS REAL) WHERE id = 'session:t1'")
        }
        XCTAssertEqual(try database.first("PRAGMA integrity_check")?.text(0), "ok")
        database.close()

        // The next start follows all of it.
        store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false, now: { clock.tick() })
        let live = try await store.notes(.init(owner: .hoot)).map(\.id)
        XCTAssertEqual(live, [real.id])
        let archivedNow = try await store.notes(.init(owner: .hoot, archivedOnly: true))
        let gone = try XCTUnwrap(archivedNow.first)
        XCTAssertEqual(gone.id, hootTest.id); XCTAssertEqual(gone.archiveReason, "test"); XCTAssertEqual(gone.path, "archive/" + hootTest.path)
        XCTAssertEqual(gone.body, "Also not real.", "kept word for word")
        let scratchFound = try await store.note(id: testNote.id)
        let scratchNote = try XCTUnwrap(scratchFound)
        XCTAssertTrue(scratchNote.isArchived); XCTAssertEqual(scratchNote.archiveReason, "test"); XCTAssertEqual(scratchNote.path, "archive/" + testNote.path)
        let seats = try await store.owners().map(\.owner)
        XCTAssertFalse(seats.contains(scratch), "the scratch seat is no longer listed"); XCTAssertTrue(seats.contains(.hoot))
        let topics = try await store.topics(.hoot, includeClosed: false), allTopics = try await store.topics(.hoot, includeClosed: true)
        XCTAssertTrue(topics.isEmpty); XCTAssertEqual(allTopics.map(\.id), ["test-topic"])
        let board = try await store.board(.init()), allBoard = try await store.board(.init(includeArchived: true))
        XCTAssertTrue(board.isEmpty); XCTAssertEqual(allBoard.count, 1)
        let said = try await store.diary(.init(owner: scratch))
        XCTAssertEqual(said.map(\.text), ["typed by a builder's test"]); XCTAssertEqual(said.first?.author, .tool); XCTAssertEqual(said.first?.meta["source"], "dev-test")
        let search = try await store.search(.init("real", owner: .hoot, kinds: [.note], mode: .words))
        XCTAssertEqual(search.hits.map(\.ref), [real.id], "archived test notes are out of an ordinary search")
        // And it can all be brought back.
        let back = try await store.restoreNote(id: hootTest.id)
        XCTAssertEqual(back.path, hootTest.path); XCTAssertFalse(back.isArchived)
        await store.close()
    }

    // MARK: Shipped template cards

    func testAnUntouchedTemplateCardFollowsTheAppAndAnEditedOneIsKept() async throws {
        // The first installs' cards, byte for byte: these are the hashes of the three files written into his real
        // memory folder on 11 Oct 2026 at 06:21 (read there, not changed).
        let first: [DeckMemoryCategory: String] = [.orchestrator: "7422d33d21f3c0cc", .lead: "2ecbb6a66ce8e1d2", .agent: "641fa67e3a130911"]
        // The second version's cards, read in his real install on 11 Oct 2026 at 13:2x (after its 08:25 start upgraded them).
        let second: [DeckMemoryCategory: String] = [.orchestrator: "171d6031521deac0", .lead: "396f47478508dc52", .agent: "b8fc12e483ae6515"]
        for (category, hash) in first {
            let earlier = DeckMemoryStore.earlierShippedCards(category)
            XCTAssertEqual(earlier.count, 2)
            XCTAssertTrue(DeckMemoryFiles.hash(earlier[0]).hasPrefix(hash), "\(category.rawValue): the kept first text is not the one that was installed")
            XCTAssertTrue(DeckMemoryFiles.hash(earlier[1]).hasPrefix(second[category]!), "\(category.rawValue): the kept second text is not the one in his install")
        }
        // Every shipped card says how the tools are called and to search once per fact, one line each, and stays small.
        let line = "- To use a memory tool: look it up with tools_describe (it shows the tool's arguments), then call it with tools_run.\n"
        let perFact = "- When a question needs several facts, search once for each fact.\n"
        for category in DeckMemoryCategory.allCases {
            let card = DeckMemoryStore.shippedCard(category)
            XCTAssertEqual(card.components(separatedBy: line).count, 2, category.rawValue)
            XCTAssertEqual(card.replacingOccurrences(of: perFact, with: ""), DeckMemoryStore.earlierShippedCards(category)[1], "version 3 adds only that line")
            XCTAssertEqual(card.replacingOccurrences(of: perFact, with: "").replacingOccurrences(of: line, with: ""), DeckMemoryStore.earlierShippedCards(category)[0])
            XCTAssertLessThan(card.count, 1_300, category.rawValue)
        }
        XCTAssertLessThan(DeckMemoryStore.shippedCard(.agent).count, DeckMemoryCard.defaultLimit / 4, "the Agent card leaves most of the size cap to the seat's own card")

        // An install made by the earlier app: the Agent and Orchestrator cards untouched, the Lead card edited by the person.
        let data = try temp("data"), root = try temp("root").appendingPathComponent("Memory")
        var store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false)
        await store.close()
        let oldAgent = DeckMemoryStore.earlierShippedCards(.agent)[0], oldOrchestrator = DeckMemoryStore.earlierShippedCards(.orchestrator)[0]
        let edited = DeckMemoryStore.earlierShippedCards(.lead)[0] + "\n## My own rule\n- Ask me before spending money.\n"
        try write(root, "templates/agent/card.md", oldAgent)
        try write(root, "templates/orchestrator/card.md", oldOrchestrator)
        try write(root, "templates/lead/card.md", edited)
        try write(root, "templates/agent/checklist.md", "# Mine\n- my own checklist line\n")

        // The next start of the new app.
        store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false)
        XCTAssertEqual(read(root, "templates/agent/card.md"), DeckMemoryStore.shippedCard(.agent), "untouched: it follows the app")
        XCTAssertEqual(read(root, "templates/orchestrator/card.md"), DeckMemoryStore.shippedCard(.orchestrator))
        XCTAssertEqual(read(root, "templates/lead/card.md"), edited, "edited by the person: left exactly as it is, nothing added")
        XCTAssertEqual(read(root, "templates/agent/checklist.md"), "# Mine\n- my own checklist line\n", "other template files are not touched")
        // The earlier text was kept, not thrown away.
        let kept = DeckMemoryFiles.markdown(under: root.appendingPathComponent("archive/versions/templates/agent")).filter { $0.hasPrefix("card.") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(read(root, "archive/versions/templates/agent/" + kept[0]), oldAgent)
        XCTAssertTrue(DeckMemoryFiles.markdown(under: root.appendingPathComponent("archive/versions/templates/lead")).isEmpty)
        // What a seat is given carries the line; a seat under the edited Lead card gets the person's text.
        let agentCard = try await store.assembledCard(iosSeat), leadCard = try await store.assembledCard(.lead("crm"))
        XCTAssertTrue(agentCard.text.contains("then call it with tools_run")); XCTAssertEqual(agentCard.overBy, 0)
        XCTAssertTrue(leadCard.text.contains("Ask me before spending money.")); XCTAssertFalse(leadCard.text.contains("tools_run"))
        await store.close()
        // Starting again changes nothing more.
        store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false)
        XCTAssertEqual(read(root, "templates/agent/card.md"), DeckMemoryStore.shippedCard(.agent))
        XCTAssertEqual(DeckMemoryFiles.markdown(under: root.appendingPathComponent("archive/versions/templates/agent")).filter { $0.hasPrefix("card.") }.count, 1)
        await store.close()
    }

    func testADiarySearchHitNamesWhoReallyWroteIt() async throws {
        let (store, _, _) = try await open()
        let seat = DeckMemoryOwner.role(project: "imatch", role: "ios")
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "lantern check one: typed by the person", author: .person))
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "lantern check two: sent by a builder's test from code", meta: ["source": "dev-test"], author: .tool))
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "lantern check three: Hoot asking a session", author: .orchestrator))
        _ = try await store.appendDiary(.init(stamp: .init(owner: seat, session: "s1", agent: "ios-dev-2"), role: .assistant, text: "lantern check four: the agent answering", author: .agent))
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "lantern check five: an old row with no author"))
        let found = try await store.search(.init("lantern check", kinds: [.diary], mode: .words, limit: 10))
        let names = Dictionary(uniqueKeysWithValues: found.hits.map { ($0.snippet.components(separatedBy: ":")[0], $0.title.components(separatedBy: ",")[0]) })
        XCTAssertEqual(names["lantern check one"], "You")
        XCTAssertEqual(names["lantern check two"], "Builder test", "a builder's test row is never the person's")
        XCTAssertEqual(names["lantern check three"], "Hoot")
        XCTAssertEqual(names["lantern check four"], "ios-dev-2")
        XCTAssertEqual(names["lantern check five"], "You", "older rows without an author fall back to the role")
        await store.close()
    }

    // MARK: Answers spread over several messages

    func testNearDuplicatesArePushedDownSoTheTopCoversDifferentThings() async throws {
        let (store, _, _) = try await open()
        for version in 1...4 {
            _ = try await store.addNote(.init(title: "Handoff draft \(version)", body: "The person used topic \(version) to test how Hoot starts sessions: start a bug-fix session, check the playbook, report back.", stamp: .hoot))
        }
        let other = try await store.addNote(.init(title: "Sessions Hoot reported on", body: "Hoot reported on session f5f182f0 and session 2c6070f9.", stamp: .hoot))
        let found = try await store.search(.init("Hoot sessions", kinds: [.note], mode: .words, limit: 3))
        XCTAssertTrue(found.hits.prefix(2).contains { $0.ref == other.id }, "the one different note is not buried under four versions of one draft: \(found.hits.map(\.title))")
        let all = try await store.search(.init("Hoot sessions", kinds: [.note], mode: .words, limit: 10))
        XCTAssertEqual(all.hits.count, 5, "the near-duplicates are pushed down, not dropped")
        await store.close()
    }

    func testACompoundQuestionGetsTheBestAnswerToEachPart() async throws {
        XCTAssertEqual(DeckMemoryStore.questionParts("what is waiting on Asad for Vishal and when were the CRM questions answered"),
                       ["what is waiting on Asad for Vishal", "when were the CRM questions answered"])
        XCTAssertEqual(DeckMemoryStore.questionParts("who leads CRM, and who leads iMatch?"), ["who leads CRM", "who leads iMatch"])
        XCTAssertEqual(DeckMemoryStore.questionParts("can we sign and upload iOS builds without him"), [], "a part with one real word is not a part")
        XCTAssertEqual(DeckMemoryStore.questionParts("which colour for the primary action"), [])
        let (store, _, _) = try await open()
        let vishal = try await store.addNote(.init(title: "Vishal's Android fix list waits on Asad", body: "Session f5f182f0 holds a 31-item list for Vishal; it is sent only when Asad says send it.", stamp: .hoot))
        let crm = try await store.addNote(.init(title: "CRM questions settled", body: "Both CRM questions were answered on 6 Oct in session 2c6070f9.", stamp: .hoot))
        for index in 1...6 { _ = try await store.addNote(.init(title: "Waiting list \(index)", body: "Asad waiting item \(index) for Vishal about the Android build.", stamp: .hoot)) }
        let found = try await store.search(.init("what is waiting on Asad for Vishal and when were the CRM questions answered", kinds: [.note], mode: .words, limit: 3))
        let refs = found.hits.map(\.ref)
        XCTAssertTrue(refs.contains(crm.id), "the second part's answer is in the top three: \(found.hits.map(\.title))")
        XCTAssertTrue(refs.contains(vishal.id) || found.hits.contains { $0.title.hasPrefix("Waiting list") }, "the first part is answered too")
        await store.close()
    }

    func testAShortReplyComesWithTheMessagesAroundIt() async throws {
        let (store, _, _) = try await open()
        func say(_ role: DeckMemoryDiaryRole, _ text: String, _ author: DeckMemoryAuthor) async throws {
            _ = try await store.appendDiary(.init(stamp: .hoot, role: role, text: text, conversation: "c1", author: author))
        }
        try await say(.assistant, "Shall I move the memory folder to ~/Terminal Deck Memory, keeping the old one as an archive?", .orchestrator)
        try await say(.user, "yes, archive it", .person)
        try await say(.assistant, "Moved. The old folder stays where it was, as an archive, with a MOVED.md note saying where the memory went.", .orchestrator)
        let found = try await store.search(.init("archive it", kinds: [.diary], mode: .words))
        let hit = try XCTUnwrap(found.hits.first { $0.snippet.contains("yes, archive it") })
        let context = try XCTUnwrap(hit.context)
        XCTAssertTrue(context.contains("Just before (Hoot): Shall I move the memory folder"), context)
        XCTAssertTrue(context.contains("Just after (Hoot): Moved."), context)
        let long = try XCTUnwrap(found.hits.first { $0.snippet.contains("MOVED.md") })
        XCTAssertNil(long.context, "a message that stands on its own gets nothing added")
        await store.close()
    }

    // MARK: Questions, values, backup, live changes

    func testQuestionsValuesAndBackup() async throws {
        let (store, root, _) = try await open()
        let question = try await store.addQuestion(owner: .hoot, text: "Two notes disagree about the ship order. Which holds?", context: "n-1 vs n-2", refs: ["n-1", "n-2"])
        let same = try await store.addQuestion(owner: .hoot, text: "Two notes disagree about the ship order. Which holds?", context: "", refs: [])
        XCTAssertEqual(same.id, question.id, "the same open question is asked once")
        let open = try await store.questions(owner: .hoot, openOnly: true)
        XCTAssertEqual(open.map(\.refs), [["n-1", "n-2"]])
        let answered = try await store.answerQuestion(id: question.id, answer: "Mac first.")
        XCTAssertFalse(answered.isOpen); XCTAssertEqual(answered.state, .answered)
        let left = try await store.questions(owner: nil, openOnly: true), all = try await store.questions(owner: nil, openOnly: false)
        XCTAssertTrue(left.isEmpty); XCTAssertEqual(all.first?.answer, "Mac first.")
        // Something the person waved away is kept on the Dismissed list and is never raised again.
        let rule = try await store.addQuestion(owner: .hoot, text: "Make “short replies” a top rule?", context: "said on three days", refs: [])
        let waved = try await store.dismissQuestion(id: rule.id)
        XCTAssertTrue(waved.isDismissed); XCTAssertFalse(waved.isOpen); XCTAssertEqual(waved.state, .dismissed)
        let raisedAgain = try await store.addQuestion(owner: .hoot, text: "make “short  replies” a top rule?", context: "said on a fourth day", refs: [])
        XCTAssertEqual(raisedAgain.id, rule.id, "the dismissed question came back; no new one was made"); XCTAssertTrue(raisedAgain.isDismissed)
        let stillNoneOpen = try await store.questions(owner: .hoot, openOnly: true)
        XCTAssertTrue(stillNoneOpen.isEmpty)
        let everything = try await store.questions(owner: .hoot, openOnly: false)
        XCTAssertEqual(everything.map(\.state), [.answered, .dismissed])
        let elsewhere = try await store.addQuestion(owner: iosSeat, text: "Make “short replies” a top rule?", context: "", refs: [])
        XCTAssertTrue(elsewhere.isOpen, "another seat's question is its own")
        let back = try await store.reopenQuestion(id: rule.id)
        XCTAssertTrue(back.isOpen)
        try await store.setValue("41", key: DeckMemoryKeys.helperCursor + ".s1", owner: nil)
        try await store.setValue("2026-10-11T00:00:00Z", key: DeckMemoryKeys.helperLastRun, owner: iosSeat)
        let cursor = try await store.value(DeckMemoryKeys.helperCursor + ".s1", owner: nil), other = try await store.value(DeckMemoryKeys.helperLastRun, owner: .hoot)
        XCTAssertEqual(cursor, "41"); XCTAssertNil(other)
        let backup = try await store.backup()
        XCTAssertTrue(backup.path.hasPrefix(root.appendingPathComponent("archive/backups").path)); XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        await store.close()
    }

    func testChangesAreAnnounced() async throws {
        let (store, _, _) = try await open()
        let stream = store.changes()
        let listener = Task { () -> [DeckMemoryChange] in
            var seen: [DeckMemoryChange] = []
            for await change in stream { seen.append(change); if seen.count == 3 { break } }
            return seen
        }
        let note = try await store.addNote(.init(title: "Announced", body: "x", stamp: .hoot))
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "hello"))
        var template = try await store.template(.lead); template.checklist += "\n- One more thing to look for.\n"
        _ = try await store.saveTemplate(template)
        let seen = await listener.value
        XCTAssertEqual(seen.map(\.area), [.notes, .diary, .templates])
        XCTAssertEqual(seen[0].ref, note.id); XCTAssertEqual(seen[0].owner, .hoot); XCTAssertEqual(seen[2].ref, "lead"); XCTAssertNil(seen[2].owner)
        await store.close()
    }
}

extension DeckMemoryStore {
    /// Diary vectors straight into the index, newer than everything before them: weeks of messages in a moment.
    func addDiaryVectors(_ count: Int, pointing vector: [Float]) throws {
        let model = embedder?.model ?? ""
        try db.transaction {
            for index in 0..<count {
                try db.run("INSERT INTO embeddings (kind, ref, piece, owner, archived, model, vector) VALUES ('diary', ?, 0, ?, 0, ?, ?)",
                           [.text(String(900_000 + index)), .text(DeckMemoryOwner.hoot.key), .text(model), .blob(DeckMemoryVectors.data(vector))])
            }
        }
    }
}
