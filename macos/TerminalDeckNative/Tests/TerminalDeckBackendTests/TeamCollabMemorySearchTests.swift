import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Answers fast for stored texts and hangs on the question itself, as the meaning model can on a busy Mac.
private struct TeamCollabHangingEmbedder: DeckMemoryEmbedding {
    var model: String { "hanging-1" }
    func vector(for text: String) async -> [Float]? {
        if text == "lantern" { try? await Task.sleep(for: .seconds(60)); return nil }
        return [1, 0, 0]
    }
}

/// 30 Oct (Decker's collaboration problem 6: memory_search timed out): a search whose meaning part hangs still answers,
/// by words, within its budget.
final class TeamCollabMemorySearchTests: XCTestCase {
    func testAHangingMeaningModelStillAnswersByWordsInTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-team-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await DeckMemoryStore.open(root: root.appendingPathComponent("memory"), dataRoot: root, embedder: TeamCollabHangingEmbedder(), watch: false)
        _ = try await store.addNote(.init(title: "Lantern build", body: "The lantern build runs in the background.", type: .decision, stamp: .hoot))
        let started = Date()
        let found = try await store.search(.init("lantern", mode: .both, limit: 5))
        let took = Date().timeIntervalSince(started)
        XCTAssertLessThan(took, DeckMemoryStore.questionVectorSeconds + 10, "took \(took) s")
        XCTAssertFalse(found.usedMeaning)
        XCTAssertTrue(found.hits.contains { $0.title == "Lantern build" })
        await store.close()
    }
}
