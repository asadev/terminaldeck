import Foundation
import CoreML
import TerminalDeckNativeCore

/// The uncased BERT WordPiece tokenizer the bundled model was trained with, written to give the same token ids as
/// the reference (Hugging Face `tokenizers`: BertNormalizer with lowercase and accent stripping, BertPreTokenizer,
/// WordPiece with "##"). Checked against the reference on `macos/dev/memory-check/tokenizer-check.json`.
public struct DeckMemoryWordPiece: Sendable {
    private let vocabulary: [String: Int32]
    public let unknown: Int32, start: Int32, end: Int32
    public static let maxCharactersPerWord = 100

    public init(vocabulary url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: Int32] = [:]
        for (index, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty { table[line] = Int32(index) }
        guard let unknown = table["[UNK]"], let start = table["[CLS]"], let end = table["[SEP]"] else {
            throw DeckMemoryError(.unavailable, "The meaning model's vocabulary is incomplete.")
        }
        vocabulary = table; self.unknown = unknown; self.start = start; self.end = end
    }

    /// `[CLS]` + pieces + `[SEP]`, at most `maxTokens` long.
    public func encode(_ text: String, maxTokens: Int = 512) -> [Int32] {
        var ids: [Int32] = [start]
        let room = max(0, maxTokens - 2)
        words: for word in Self.words(text) {
            for piece in pieces(word) {
                guard ids.count - 1 < room else { break words }
                ids.append(piece)
            }
        }
        ids.append(end)
        return ids
    }

    /// Greedy longest-match-first; a word that cannot be split into known pieces is one `[UNK]`.
    func pieces(_ word: String) -> [Int32] {
        let characters = Array(word)
        guard characters.count <= Self.maxCharactersPerWord else { return [unknown] }
        var out: [Int32] = [], begin = 0
        while begin < characters.count {
            var finish = characters.count, found: Int32?
            while begin < finish {
                let piece = (begin > 0 ? "##" : "") + String(characters[begin..<finish])
                if let id = vocabulary[piece] { found = id; break }
                finish -= 1
            }
            guard let found else { return [unknown] }
            out.append(found); begin = finish
        }
        return out
    }

    /// Clean, space out CJK ideographs, strip accents, lowercase, then split on whitespace and punctuation.
    static func words(_ text: String) -> [String] {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || isControl(scalar) { continue }
            if isWhitespace(scalar) { cleaned.append(" ") }
            else if isCJK(scalar) { cleaned.append(" "); cleaned.append(scalar); cleaned.append(" ") }
            else { cleaned.append(scalar) }
        }
        var words: [String] = [], current = String.UnicodeScalarView()
        func flush() { if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() } }
        for scalar in String(cleaned).decomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            for lower in scalar.properties.lowercaseMapping.unicodeScalars {
                if isWhitespace(lower) { flush() }
                else if isPunctuation(lower) { flush(); words.append(String(lower)) }
                else { current.append(lower) }
            }
        }
        flush()
        return words
    }
    static func isWhitespace(_ s: Unicode.Scalar) -> Bool { s == "\t" || s == "\n" || s == "\r" || s.properties.isWhitespace }
    static func isControl(_ s: Unicode.Scalar) -> Bool {
        if s == "\t" || s == "\n" || s == "\r" { return false }
        switch s.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse, .surrogate: return true
        default: return false
        }
    }
    static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .closePunctuation, .finalPunctuation, .initialPunctuation, .otherPunctuation, .openPunctuation: return true
        default: return false
        }
    }
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v) || (0x2A700...0x2B73F).contains(v)
            || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}

/// gte-small (MIT), bundled with the app as a Core ML model: 33 million parameters, int8 weights, 384-number vectors.
/// Runs on the Mac (Neural Engine, GPU or CPU, as Core ML decides). Nothing is downloaded, nothing leaves the Mac.
/// Chosen on 11 Oct 2026 on a 30-question paraphrase check (macos/dev/memory-check/paraphrase.json): right note first
/// 22 of 30, in the first three 26 (Apple's sentence embedding: 5 and 12; all-MiniLM-L6-v2 19 and 26; bge-small 20 and 23).
public final class DeckMemoryCoreMLEmbedder: DeckMemoryEmbedding, @unchecked Sendable {
    /// The folder inside the app's Resources (or named by `TD_DECKMEMORY_EMBEDDING_DIR`).
    public static let folderName = "deck-memory-embedding"
    static let modelFile = "gte-small.mlmodelc", vocabularyFile = "vocab.txt"
    /// Names the vectors. Change it whenever the model files change: the store then makes every vector again.
    public let model = "gte-small-int8-1"
    /// gte-small puts every text in a narrow band (about 0.75 to 0.9). Calibrated on the paraphrase check through the
    /// store's own search (11 Oct 2026): floor 0.78 to 0.80 all give 22 of 30 right first; 0.80 leaves the fewest
    /// no-answer questions with a result (4 of 6, against 6 at 0.78); 0.82 starts losing right answers (20 of 30).
    /// Beside a full word match a meaning-only hit must reach 0.83, the median score of a right answer.
    public var meaningFloor: Double { 0.80 }
    public var meaningFloorBesideWords: Double { 0.83 }
    /// Unrelated texts score up to about 0.87 and different versions of one document 0.95 and above.
    public var duplicateSimilarity: Double { 0.95 }

    private let folder: URL
    private let lock = NSLock()
    private var loaded: (model: MLModel, tokenizer: DeckMemoryWordPiece)?
    private var failed = false

    /// Checks the files are there; the model itself is loaded on first use, off the main thread.
    public init?(folder: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: folder.appendingPathComponent(Self.modelFile).path),
              files.fileExists(atPath: folder.appendingPathComponent(Self.vocabularyFile).path) else { return nil }
        self.folder = folder
    }

    private func ready() -> (model: MLModel, tokenizer: DeckMemoryWordPiece)? {
        if let loaded { return loaded }
        guard !failed else { return nil }
        do {
            let configuration = MLModelConfiguration(); configuration.computeUnits = .all
            let model = try MLModel(contentsOf: folder.appendingPathComponent(Self.modelFile), configuration: configuration)
            let tokenizer = try DeckMemoryWordPiece(vocabulary: folder.appendingPathComponent(Self.vocabularyFile))
            loaded = (model, tokenizer)
            return loaded
        } catch {
            failed = true
            NSLog("[memory] the bundled meaning model could not be loaded, so search uses words only: %@", error.localizedDescription)
            return nil
        }
    }

    public func vector(for text: String) async -> [Float]? {
        lock.withLock {
            guard let (model, tokenizer) = ready() else { return nil }
            let ids = tokenizer.encode(text)
            do {
                let shape = [1, NSNumber(value: ids.count)]
                let input = try MLMultiArray(shape: shape, dataType: .int32), mask = try MLMultiArray(shape: shape, dataType: .int32)
                let inputPointer = input.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
                let maskPointer = mask.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
                for (index, id) in ids.enumerated() { inputPointer[index] = id; maskPointer[index] = 1 }
                let output = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": mask]))
                guard let values = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
                return (0..<values.count).map { values[$0].floatValue }
            } catch {
                NSLog("[memory] the meaning model could not read a text: %@", error.localizedDescription)
                return nil
            }
        }
    }
}

/// Which embedding this copy of the app uses: the bundled model when it is there, else Apple's sentence embedding,
/// else none (search by words only).
public enum DeckMemoryEmbedders {
    public static let environmentKey = NativeLaunchSwitches.memoryModelFolder
    public static func bundledFolder(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        if let custom = environment[environmentKey], custom.hasPrefix("/") { return URL(fileURLWithPath: custom, isDirectory: true) }
        return bundle.resourceURL?.appendingPathComponent(DeckMemoryCoreMLEmbedder.folderName, isDirectory: true)
    }
    private static let chosen: (any DeckMemoryEmbedding)? = {
        if let folder = bundledFolder(), let model = DeckMemoryCoreMLEmbedder(folder: folder) { return model }
        return DeckMemoryNLEmbedder.shared
    }()
    /// Without loading anything (tests, scratch stores). The app uses `choose()` instead.
    public static func preferred() -> (any DeckMemoryEmbedding)? { chosen }

    public struct Choice: Sendable {
        public let embedder: (any DeckMemoryEmbedding)?
        /// One plain line for the app's log: which model search by meaning uses, and why when it is not the bundled one.
        public let description: String
    }
    /// What the app opens memory with: loads the bundled model and runs one sentence through it; if the model is not in
    /// this copy of the app or does not load, Apple's sentence embedding; if that is missing too, words only. Call it
    /// off the main thread (loading takes a fraction of a second).
    public static func choose(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) async -> Choice {
        let apple: (any DeckMemoryEmbedding)? = DeckMemoryNLEmbedder.shared.isAvailable ? DeckMemoryNLEmbedder.shared : nil
        func fallback(_ why: String) -> Choice {
            guard let apple else { return .init(embedder: nil, description: "Memory search by meaning is OFF (words only): " + why + ", and Apple's sentence embedding is not available either.") }
            return .init(embedder: apple, description: "Memory search by meaning uses Apple's sentence embedding (" + apple.model + "), the weaker fallback: " + why + ".")
        }
        guard let folder = bundledFolder(environment: environment, bundle: bundle) else { return fallback("this copy of the app has no Resources folder") }
        guard let model = DeckMemoryCoreMLEmbedder(folder: folder) else { return fallback("the bundled model is not in this copy of the app (" + folder.path + ")") }
        let started = Date()
        guard let vector = await model.vector(for: "Terminal Deck checks its memory model."), vector.count == 384 else {
            return fallback("the bundled model is there but could not be loaded")
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return .init(embedder: model, description: "Memory search by meaning uses the bundled model gte-small (" + model.model + ", MIT, Core ML), loaded in \(ms) ms from " + folder.path + ".")
    }
}
