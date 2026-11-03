import Foundation
import NaturalLanguage

/// Turns a piece of text into numbers that sit close together when two texts mean the same thing.
/// On-device only. A nil answer means "not available here": search then falls back to words.
public protocol DeckMemoryEmbedding: Sendable {
    /// Names the model. Vectors made by different models are never compared with each other.
    var model: String { get }
    func vector(for text: String) async -> [Float]?
    /// Below this, a match by meaning is not shown at all. Each model has its own scale.
    var meaningFloor: Double { get }
    /// When word search already answered, a match by meaning alone must reach this to be shown beside it.
    var meaningFloorBesideWords: Double { get }
    /// Two texts at least this alike say the same thing: the second is pushed down in a result list.
    var duplicateSimilarity: Double { get }
}

public extension DeckMemoryEmbedding {
    /// Measured on Apple's on-device English sentence model (11 Oct 2026): a text about the same thing scores about
    /// 0.30 to 0.34, an unrelated one 0.05 to 0.26.
    var meaningFloor: Double { 0.27 }
    var meaningFloorBesideWords: Double { 0.32 }
    var duplicateSimilarity: Double { 0.92 }
}

/// Apple's NaturalLanguage sentence embedding (English). Nothing leaves the Mac and nothing is downloaded.
public final class DeckMemoryNLEmbedder: DeckMemoryEmbedding, @unchecked Sendable {
    public static let shared = DeckMemoryNLEmbedder()
    private let lock = NSLock()
    private var loaded = false
    private var embedding: NLEmbedding?
    public init() {}

    private func current() -> NLEmbedding? {
        lock.withLock {
            if !loaded { embedding = NLEmbedding.sentenceEmbedding(for: .english); loaded = true }
            return embedding
        }
    }
    public var model: String { "nl-sentence-en-" + String(NLEmbedding.currentSentenceEmbeddingRevision(for: .english)) }
    public var isAvailable: Bool { current() != nil }
    public func vector(for text: String) async -> [Float]? {
        let clean = String(text.prefix(1_200)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let embedding = current() else { return nil }
        // One at a time: NLEmbedding is not documented as safe to call from several threads at once.
        return lock.withLock { embedding.vector(for: clean)?.map(Float.init) }
    }
}

enum DeckMemoryVectors {
    static func data(_ vector: [Float]) -> Data { vector.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func vector(_ data: Data) -> [Float] {
        let size = MemoryLayout<Float>.size, count = data.count / size
        return data.withUnsafeBytes { raw in (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * size, as: Float.self) } }
    }
    /// How alike two vectors point, -1...1. 0 when either is empty or they differ in length.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, lengthA: Float = 0, lengthB: Float = 0
        for index in 0..<a.count { dot += a[index] * b[index]; lengthA += a[index] * a[index]; lengthB += b[index] * b[index] }
        guard lengthA > 0, lengthB > 0 else { return 0 }
        return Double(dot / (lengthA.squareRoot() * lengthB.squareRoot()))
    }
}
