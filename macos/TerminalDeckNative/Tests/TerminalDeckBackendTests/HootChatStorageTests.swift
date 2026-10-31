import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U129: Hoot's size limits and storage (#83, #84, #181, #186).
final class HootChatStorageTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-storage-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    private func wait(seconds: Double = 5, _ predicate: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out")
    }
    private func reply(_ events: [HootChatEvent]) -> String {
        HootChatProjection.rows(events).filter { $0.kind == .message || $0.kind == .textDelta }.compactMap { $0.value["text"].string }.joined()
    }

    // #83: a healthy CLI whose output is read as it comes is never killed for its lifetime total.
    func testLongLivedOutputThatIsReadIsNeverCapped() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let child = BackendHootChatProcess(), size = 40 * 1_048_576
        try child.start(.init(command: "/bin/sh", arguments: ["-c", "head -c \(size) /dev/zero"], cwd: root.path, environment: [:]))
        var total = 0, code: Int32?
        for await event in child.output {
            switch event {
            case .stdout(let bytes): total += bytes.count
            case .stderr: break
            case .exit(let value): code = value
            }
        }
        XCTAssertEqual(total, size, "Every byte past the old 32 MiB lifetime cap arrives")
        XCTAssertEqual(code, 0, "The CLI ends by itself, not by the app's stop")
    }
    // #83: what the reader has not taken yet is still capped.
    func testUnreadBacklogIsStillCapped() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let child = BackendHootChatProcess()
        try child.start(.init(command: "/bin/sh", arguments: ["-c", "head -c \(BackendHootChatProcess.backlogLimit + 16 * 1_048_576) /dev/zero; sleep 30"],
                              cwd: root.path, environment: [:]))
        try await wait(seconds: 20) { !child.alive }
        var total = 0, code: Int32?
        for await event in child.output {
            switch event {
            case .stdout(let bytes): total += bytes.count
            case .stderr: break
            case .exit(let value): code = value
            }
        }
        XCTAssertLessThanOrEqual(total, BackendHootChatProcess.backlogLimit)
        XCTAssertNotEqual(code, 0, "The app stopped the CLI whose output nobody read")
    }

    // #84: past the size limit the oldest parts go; the write never fails and the file stays readable.
    func testOverTheSizeLimitTheOldestPartsGoInsteadOfFailingEveryWrite() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        let store = try BackendHootChatStore(file: file)
        let pieces = (0..<24).map { index in
            DeckMemoryFlowPiece(role: index % 2 == 0 ? .user : .assistant, text: String(index) + ":" + String(repeating: "x", count: 900_000), at: nil, key: String(index))
        }
        try await store.seedTerminalHistory(pieces, conversation: nil)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, BackendHootChatStore.historyByteLimit)
        let saved = try BackendHootChatStore.readHistory(file: file, provider: .claude)
        let texts = saved.events.compactMap { $0.record.value["text"].string }
        XCTAssertTrue(texts.contains { $0.hasPrefix("23:") }, "The newest words stay")
        XCTAssertFalse(texts.contains { $0.hasPrefix("0:") }, "The oldest words went")
        XCTAssertTrue(texts.allSatisfy { $0.count == 0 || $0.count > 900_000 }, "Kept words are kept whole")
    }
    // #84: one part bigger than the whole limit keeps its start and says it was cut.
    func testOnePartBiggerThanTheLimitKeepsItsStart() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        let store = try BackendHootChatStore(file: file)
        let huge = "start-" + String(repeating: "y", count: 17 * 1_048_576)
        try await store.seedTerminalHistory([DeckMemoryFlowPiece(role: .user, text: "Read it", at: nil, key: "0"),
                                             DeckMemoryFlowPiece(role: .assistant, text: huge, at: nil, key: "1")], conversation: nil)
        let saved = try BackendHootChatStore.readHistory(file: file, provider: .claude)
        let kept = try XCTUnwrap(saved.events.compactMap { $0.record.value["text"].string }.first { $0.hasPrefix("start-") })
        XCTAssertLessThan(kept.count, 70_000)
        XCTAssertTrue(kept.hasSuffix("KB too large to keep)"))
    }

    // #181: streamed words are written in batches, and still reach the file without waiting for the turn to end.
    func testStreamedWordsAreWrittenInBatches() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        let store = try BackendHootChatStore(file: file)
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}}"#
        let script = "read first; printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"cli-session\"}' "
            + "'{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\",\"message\":{\"id\":\"m1\"}}}'; "
            + "i=0; while [ $i -lt 200 ]; do printf '%s\\n' '\(delta)'; i=$((i+1)); done; read more"
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", script], cwd: root.path, environment: [:]))
        let before = await store.historyWrites
        _ = try await store.say("hello")
        let words = String(repeating: "a", count: 200)
        try await wait {
            let events = (await store.snapshot(limit: 500)["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }
            return self.reply(events) == words
        }
        try await wait { (try? BackendHootChatStore.readHistory(file: file, provider: .claude)).map { self.reply($0.events) } == words }
        let writes = await store.historyWrites - before
        XCTAssertLessThan(writes, 20, "200 streamed words, not 200 whole-file writes")
        await store.stop()
    }

    // #186: each New chat keeps a copy of the old one, but only the newest few copies stay.
    func testOnlyTheNewestChatCopiesStay() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        var newest = ""
        for _ in 0..<(BackendHootChatStore.keptArchives + 3) {
            newest = try await store.newConversation()["archivedPath"].string ?? ""
        }
        let archives = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("chat-archive-") && $0.hasSuffix(".json") }
        XCTAssertEqual(archives.count, BackendHootChatStore.keptArchives)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest), "The copy just made stays")
    }
}
