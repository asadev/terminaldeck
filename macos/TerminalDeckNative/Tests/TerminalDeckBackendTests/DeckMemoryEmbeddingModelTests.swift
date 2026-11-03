import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The bundled meaning model (gte-small, Core ML) and the search built on it.
final class DeckMemoryEmbeddingModelTests: XCTestCase {
    /// `macos/` in this checkout, found from this file.
    private static let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let modelFolder = macos.appendingPathComponent("models/deck-memory-embedding")
    private static let checks = macos.appendingPathComponent("dev/memory-check")
    private var folders: [URL] = []
    override func tearDown() async throws { for folder in folders { try? FileManager.default.removeItem(at: folder) }; folders = [] }
    private func temp() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("td-deck-memory-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); folders.append(folder)
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }
    private func model() throws -> DeckMemoryCoreMLEmbedder {
        try XCTUnwrap(DeckMemoryCoreMLEmbedder(folder: Self.modelFolder), "the model folder is missing: \(Self.modelFolder.path)")
    }

    func testTheTokenizerGivesTheReferenceIds() throws {
        struct Case: Decodable { let text: String; let ids: [Int32] }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.checks.appendingPathComponent("tokenizer-check.json")))
        let tokenizer = try DeckMemoryWordPiece(vocabulary: Self.modelFolder.appendingPathComponent("vocab.txt"))
        XCTAssertGreaterThan(cases.count, 20)
        for item in cases { XCTAssertEqual(tokenizer.encode(item.text), item.ids, item.text.debugDescription) }
    }

    func testTheModelMakesNormalisedVectorsQuickly() async throws {
        let embedder = try model()
        let made = await embedder.vector(for: "Deploy means a release to TestFlight.")
        let first = try XCTUnwrap(made)
        XCTAssertEqual(first.count, 384)
        XCTAssertEqual(Double(first.reduce(0) { $0 + $1 * $1 }).squareRoot(), 1, accuracy: 0.01)
        let again = await embedder.vector(for: "Deploy means a release to TestFlight.")
        let same = try XCTUnwrap(again)
        XCTAssertEqual(DeckMemoryVectors.cosine(first, same), 1, accuracy: 0.0001)
        let started = Date()
        for index in 0..<20 { _ = await embedder.vector(for: "Before cleaning memory.db take a fresh backup, number \(index).") }
        let each = Date().timeIntervalSince(started) / 20 * 1000
        XCTAssertLessThan(each, 150, "\(Int(each)) ms per short text")
        print("MEASURE bundled model: \(String(format: "%.1f", each)) ms per short text")
    }

    // MARK: The paraphrase check through the store's own search

    private struct Floored: DeckMemoryEmbedding {
        let base: any DeckMemoryEmbedding; let floor: Double; let beside: Double
        var model: String { base.model }
        func vector(for text: String) async -> [Float]? { await base.vector(for: text) }
        var meaningFloor: Double { floor }
        var meaningFloorBesideWords: Double { beside }
    }
    private struct Paraphrase: Decodable {
        struct Note: Decodable { let id: String; let title: String; let body: String }
        struct Question: Decodable { let ask: String; let expect: String }
        let notes: [Note]; let questions: [Question]
    }
    private static let noAnswer = ["which build number is installed on his phone right now", "what is the server password", "what did we decide about the logo font",
                                   "who is the accountant for the shop", "what time is the dentist appointment", "what is the wifi password at the office"]
    /// Right first / in the first three, through search(mode:), plus how many no-answer questions still got a result.
    private func run(_ embedder: (any DeckMemoryEmbedding)?, mode: DeckMemorySearchMode) async throws -> (first: Int, top3: Int, noAnswerHit: Int) {
        let set = try JSONDecoder().decode(Paraphrase.self, from: Data(contentsOf: Self.checks.appendingPathComponent("paraphrase.json")))
        let data = try temp(), root = data.appendingPathComponent("Memory")
        let store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: embedder, watch: false)
        var idOf: [String: String] = [:]
        for note in set.notes { idOf[try await store.addNote(.init(title: note.title, body: note.body, stamp: .hoot)).id] = note.id }
        await store.finishEmbedding()
        var first = 0, top3 = 0, empty = 0, ranks: [String] = []
        for question in set.questions {
            let hits = try await store.search(.init(question.ask, kinds: [.note], mode: mode, limit: 5)).hits.compactMap { idOf[$0.ref] }
            if hits.first == question.expect { first += 1 }
            if hits.prefix(3).contains(question.expect) { top3 += 1 }
            ranks.append(question.expect + "=" + (hits.firstIndex(of: question.expect).map { String($0 + 1) } ?? "-"))
        }
        if let out = ProcessInfo.processInfo.environment["TD_PARAPHRASE_RANKS"], embedder?.model == "gte-small-int8-1", mode == .both {
            try? ranks.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        for ask in Self.noAnswer where !(try await store.search(.init(ask, kinds: [.note], mode: mode, limit: 5)).hits.isEmpty) { empty += 1 }
        await store.close()
        return (first, top3, empty)
    }

    func testTheBundledModelFindsParaphrasesAppleModelMisses() async throws {
        let bundled = try model()
        let words = try await run(nil, mode: .words)
        let apple = try await run(DeckMemoryNLEmbedder.shared.isAvailable ? DeckMemoryNLEmbedder.shared : nil, mode: .both)
        let strong = try await run(bundled, mode: .both)
        let meaningOnly = try await run(bundled, mode: .meaning)
        print("MEASURE paraphrase (30, through search): words only \(words.first)/\(words.top3) · Apple \(apple.first)/\(apple.top3) · bundled \(strong.first)/\(strong.top3) (meaning alone \(meaningOnly.first)/\(meaningOnly.top3)) · no-answer questions with a result: words \(words.noAnswerHit)/6, Apple \(apple.noAnswerHit)/6, bundled \(strong.noAnswerHit)/6")
        XCTAssertGreaterThanOrEqual(strong.first, 18); XCTAssertGreaterThanOrEqual(strong.top3, 24)
        XCTAssertGreaterThan(strong.first, apple.first + 8)
        XCTAssertGreaterThanOrEqual(strong.first, words.first, "meaning only ever adds to what the words find")
    }

    /// Calibration helper: prints the paraphrase numbers for a range of thresholds. Run by hand (it is skipped unless asked).
    func testCalibrateThresholds() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_MEMORY_CALIBRATE"] == "1", "set TD_MEMORY_CALIBRATE=1 to run")
        let bundled = try model()
        for floor in [0.78, 0.79, 0.80, 0.81, 0.82] {
            for beside in [0.80, 0.81, 0.82, 0.83, 0.85] where beside >= floor {
                let result = try await run(Floored(base: bundled, floor: floor, beside: beside), mode: .both)
                print("CALIBRATE floor \(floor) beside \(beside): first \(result.first)/30 top3 \(result.top3)/30 no-answer with a result \(result.noAnswerHit)/6")
            }
        }
    }

    /// The memory check (macos/dev/memory-check/questions.json) on a COPY of a real memory folder, without a running app:
    /// TD_MEMORY_CHECK_COPY=<copied memory folder> TD_MEMORY_CHECK_OUT=<hits.json> TD_MEMORY_CHECK_MODEL=apple|bundled.
    /// Asks exactly as the memory.search tool does for Hoot (whole memory, replaced notes included), then
    /// `run.py --hits <hits.json>` scores it.
    func testMemoryCheckOnACopy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let copy = environment["TD_MEMORY_CHECK_COPY"], let out = environment["TD_MEMORY_CHECK_OUT"] else {
            throw XCTSkip("set TD_MEMORY_CHECK_COPY and TD_MEMORY_CHECK_OUT to run")
        }
        struct Sheet: Decodable {
            struct Question: Decodable { let id: String; let ask: String; let top: Int?; let since: String?; let until: String? }
            let top: Int; let questions: [Question]
        }
        let sheet = try JSONDecoder().decode(Sheet.self, from: Data(contentsOf: Self.checks.appendingPathComponent("questions.json")))
        let embedder: (any DeckMemoryEmbedding)? = environment["TD_MEMORY_CHECK_MODEL"] == "apple" ? DeckMemoryNLEmbedder.shared : try model()
        let store = try await DeckMemoryStore.open(root: URL(fileURLWithPath: copy), dataRoot: try temp(), embedder: embedder, watch: false)
        // The changed-over-time chains (dev/memory-check/changed-seed.json) go into this COPY, each note with the date it
        // became true and a link to the note it replaces.
        struct Seed: Decodable { struct Chain: Decodable { struct Note: Decodable { let title: String; let body: String; let valid_from: String }; let notes: [Note] }; let chains: [Chain] }
        let seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: Self.checks.appendingPathComponent("changed-seed.json")))
        let present = Set(try await store.notes(.init(owner: .hoot, includeArchived: true, limit: 5000)).map(\.title))
        for chain in seed.chains {
            var previous: String?
            for note in chain.notes where !present.contains(note.title) {
                let made = try await store.addNote(.init(title: note.title, body: note.body, type: .decision, stamp: .hoot, supersedes: previous,
                                                         source: "helper", validFrom: DeckMemoryFiles.date(note.valid_from), author: .person))
                if made.notReplaced == nil { previous = made.id }
            }
        }
        await store.finishEmbedding()
        var answers: [String: [[String: String]]] = [:]
        for question in sheet.questions {
            let asked = DeckMemorySearchQuery(question.ask, limit: question.top ?? sheet.top, since: question.since.flatMap(DeckMemoryFiles.date),
                                              until: question.until.flatMap(DeckMemoryFiles.date), includeReplaced: true)
            // TD_MEMORY_CHECK_PLAIN=1: the search as it was before 11 Oct 13:30 (words + meaning merged by rank, nothing
            // else), for before/after numbers on the same copy.
            let hits = environment["TD_MEMORY_CHECK_PLAIN"] == "1"
                ? Array(try await store.rankedHits(asked, pool: max(asked.limit * 2, 20)).hits.prefix(asked.limit))
                : try await store.search(asked).hits
            answers[question.id] = hits.map { ["title": $0.title, "snippet": $0.snippet, "standing": $0.standing ?? "", "context": $0.context ?? "", "foundBy": $0.matchedBy.rawValue] }
        }
        await store.close()
        try JSONSerialization.data(withJSONObject: answers, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
    }

    // MARK: A new model makes every vector again, once

    func testChangingTheModelReEmbedsEverythingOnceInTheBackground() async throws {
        struct Named: DeckMemoryEmbedding {
            let model: String; let base: any DeckMemoryEmbedding
            func vector(for text: String) async -> [Float]? { await base.vector(for: text) }
        }
        let data = try temp(), root = data.appendingPathComponent("Memory")
        var store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: Named(model: "old-model", base: try model()), watch: false)
        _ = try await store.addNote(.init(title: "Invoices", body: "The September invoice to the CRM client is still not paid.", stamp: .hoot))
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "please also look at the list of running simulators", author: .person))
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .tool, text: "a tool line that is found by its words only"))
        await store.finishEmbedding()
        await store.close()
        let database = try DeckMemoryDatabase(path: root.appendingPathComponent("memory.db").path)
        let before = try database.rows("SELECT DISTINCT model FROM embeddings").map { $0.text(0) }
        database.close()
        XCTAssertEqual(before, ["old-model"])

        store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: try model(), watch: false)
        await store.finishEmbedding()
        let found = try await store.search(.init("money we are still owed", mode: .meaning))
        XCTAssertEqual(found.hits.first?.title, "Invoices"); XCTAssertTrue(found.usedMeaning)
        await store.close()
        let after = try DeckMemoryDatabase(path: root.appendingPathComponent("memory.db").path)
        XCTAssertEqual(try after.rows("SELECT DISTINCT model FROM embeddings").map { $0.text(0) }, ["gte-small-int8-1"], "the old vectors are gone")
        XCTAssertEqual(try after.first("SELECT COUNT(*) FROM embed_queue")?.int(0), 0)
        // The card, the playbook, the note and the person's diary line: the tool line is found by words only.
        XCTAssertEqual(try after.first("SELECT COUNT(DISTINCT kind || ':' || ref) FROM embeddings")?.int(0), 4)
        after.close()
        // Starting again with the same model queues nothing.
        store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: try model(), watch: false)
        let queued = try DeckMemoryDatabase(path: root.appendingPathComponent("memory.db").path)
        XCTAssertEqual(try queued.first("SELECT COUNT(*) FROM embed_queue")?.int(0), 0)
        queued.close()
        await store.close()
    }

    func testTheStartChoiceNamesTheModelAndAnyFallback() async throws {
        let bundled = await DeckMemoryEmbedders.choose(environment: [DeckMemoryEmbedders.environmentKey: Self.modelFolder.path])
        XCTAssertEqual(bundled.embedder?.model, "gte-small-int8-1")
        XCTAssertTrue(bundled.description.hasPrefix("Memory search by meaning uses the bundled model gte-small"), bundled.description)
        let empty = try temp()
        let missing = await DeckMemoryEmbedders.choose(environment: [DeckMemoryEmbedders.environmentKey: empty.path])
        XCTAssertNotEqual(missing.embedder?.model, "gte-small-int8-1")
        XCTAssertTrue(missing.description.contains("the bundled model is not in this copy of the app (" + empty.path + ")"), missing.description)
        // A broken model file: the model is found but does not load, and that is said too.
        let broken = try temp()
        try FileManager.default.copyItem(at: Self.modelFolder.appendingPathComponent("vocab.txt"), to: broken.appendingPathComponent("vocab.txt"))
        try FileManager.default.createDirectory(at: broken.appendingPathComponent("gte-small.mlmodelc"), withIntermediateDirectories: true)
        let failed = await DeckMemoryEmbedders.choose(environment: [DeckMemoryEmbedders.environmentKey: broken.path])
        XCTAssertNotEqual(failed.embedder?.model, "gte-small-int8-1")
        XCTAssertTrue(failed.description.contains("could not be loaded"), failed.description)
    }

    func testTheAppFindsTheModelInItsResourcesOrFallsBack() throws {
        let named = DeckMemoryEmbedders.bundledFolder(environment: [DeckMemoryEmbedders.environmentKey: Self.modelFolder.path])
        XCTAssertEqual(named?.path, Self.modelFolder.path)
        XCTAssertNotNil(named.flatMap(DeckMemoryCoreMLEmbedder.init(folder:)))
        XCTAssertNil(DeckMemoryCoreMLEmbedder(folder: try temp()), "an empty folder is not a model")
    }
}
