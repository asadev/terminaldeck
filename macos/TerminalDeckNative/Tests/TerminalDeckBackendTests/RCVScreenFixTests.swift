import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct RCVScreenCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
}

final class RCVScreenFixTests: XCTestCase {
    func testDistinctTargetsAndFilteredMoves() {
        let a = RCVRule(id: "a", name: "A", target: .init(kind: .agent, id: "ada"))
        let hidden = RCVRule(id: "hidden", name: "Hidden", target: .init(kind: .session, id: "s1"))
        let b = RCVRule(id: "b", name: "B", target: a.target)
        let rules = [a, hidden, b]
        XCTAssertEqual(RCVPresentation.distinctTargets(in: rules).count, 2)
        XCTAssertEqual(RCVPresentation.moveIndex("b", up: true, in: rules, visible: [a, b]), 0)
        XCTAssertEqual(RCVPresentation.moveIndex("a", up: false, in: rules, visible: [a, b]), 2)
        XCTAssertNil(RCVPresentation.moveIndex("a", up: true, in: rules, visible: [a, b]))
    }

    func testOverviewCountsFullHistoryAndDeletePrunesOnlyTheRulesThreads() async throws {
        let store = BackendRCVStore(persistence: nil, cipher: nil)
        let at = Date().timeIntervalSince1970 * 1000
        let service = BackendRCVService(store: store, dispatch: RCVFakeDispatch(), relayBase: { nil }, now: { at })
        try await service.start()
        let source = RCVSource(id: "fixture", name: "Fixture", preset: "server", auth: .init(scheme: .none), mapping: RCVPresets.server.mapping)
        let event = try XCTUnwrap(RCVEngine.normalize(body: Data("hello".utf8), headers: [:], meta: [:], source: source, receivedAt: at).first)
        try await store.update { state in
            state.sources.append(source)
            state.events = (0..<600).map { i in var copy = event; copy.id = "event-\(i)"; return copy }
            state.rules = [RCVRule(id: "delete", name: "Delete", target: .init(kind: .hoot, id: "hoot"))]
            state.threads = ["project|delete|chat|suffix": "old", "other|delete|chat": "old", "project|keep|chat": "keep", "project|delete-other|chat": "keep"]
        }
        let overview = try await service.overview()
        XCTAssertEqual(overview.events.count, 200)
        XCTAssertEqual(overview.eventCount, 600)
        XCTAssertEqual(RCVPresentation.count(.flow, in: overview), 600)
        XCTAssertEqual(overview.sources.first { $0.id == source.id }?.todayCount, 600)
        try await service.deleteRule("delete")
        let state = try await store.read()
        XCTAssertEqual(Set(state.threads.keys), ["project|keep|chat", "project|delete-other|chat"])
        await service.stop()
    }

    func testSaveDoesNotParseTheExistingRecordAgain() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/rcv-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let store = BackendRCVStore(persistence: persistence, cipher: RCVScreenCipher(), saveDelayMilliseconds: 0)
        try await store.start()
        // A save must use the in-memory state, not parse the previous record for an existence check.
        try Data("not JSON".utf8).write(to: root.appendingPathComponent(BackendRCVStore.fileName))
        try await store.update { $0.threads["project|rule|chat"] = "task" }
        XCTAssertNotNil(try persistence.read(BackendRCVStore.fileName))
    }
}
