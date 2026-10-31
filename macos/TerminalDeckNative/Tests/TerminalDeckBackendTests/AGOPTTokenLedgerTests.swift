import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGOPTTokenLedgerTests: XCTestCase, @unchecked Sendable {
    func testJSONLReadsOnlyAppendedBytesAndHandlesPartialLinesAndReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-incremental-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversation.jsonl")
        let target = BackendTaskTranscriptTarget(path: file.path, roots: [root.path])
        let reader = BackendAGOPTTokenUsage(locate: { _ in target })
        func line(_ tokens: Int) -> Data {
            Data((#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(tokens)}}}}"# + "\n").utf8)
        }
        func append(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
        let initial = line(100)
        try initial.write(to: file)
        var total = try await reader.recordedTotal(provider: "codex", target: target)
        XCTAssertEqual(total, 100)
        var read = await reader.bytesRead(); XCTAssertEqual(read, initial.count)
        total = try await reader.recordedTotal(provider: "codex", target: target)
        read = await reader.bytesRead(); XCTAssertEqual(read, initial.count)
        let update = line(150), cut = update.count / 2
        try append(Data(update.prefix(cut)))
        total = try await reader.recordedTotal(provider: "codex", target: target); XCTAssertEqual(total, 100)
        try append(Data(update.dropFirst(cut)))
        total = try await reader.recordedTotal(provider: "codex", target: target); XCTAssertEqual(total, 150)
        read = await reader.bytesRead(); XCTAssertEqual(read, initial.count + update.count)
        // Shrink the same inode: rewind cannot refund tokens.
        try line(20).write(to: file)
        total = try await reader.recordedTotal(provider: "codex", target: target); XCTAssertEqual(total, 150)
        // Replace the inode, then append a complete record with no newline.
        try line(170).write(to: file, options: .atomic)
        total = try await reader.recordedTotal(provider: "codex", target: target); XCTAssertEqual(total, 170)
        try append(Data(line(190).dropLast()))
        total = try await reader.recordedTotal(provider: "codex", target: target); XCTAssertEqual(total, 190)
        try append(Data("\n".utf8))
        total = try await reader.recordedTotal(provider: "codex", target: target); XCTAssertEqual(total, 190)
        // Cached offsets must never bypass account confinement.
        let denied = BackendTaskTranscriptTarget(path: file.path, roots: [root.appendingPathComponent("elsewhere").path])
        do { _ = try await reader.recordedTotal(provider: "codex", target: denied); XCTFail("Cached path bypassed roots") } catch {}
    }

    func testAppendedClaudeStreamingUpdatesCountEachMessageOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-claude-append-" + UUID().uuidString)
        let project = root.appendingPathComponent("projects/-scratch")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("session.jsonl")
        let target = BackendTaskTranscriptTarget(path: file.path, scope: NativeTranscriptScope(configDirectory: root.path))
        let reader = BackendAGOPTTokenUsage(locate: { _ in target })
        let first = Data((#"{"type":"assistant","message":{"id":"a","usage":{"input_tokens":100,"output_tokens":5}}}"# + "\n").utf8)
        try first.write(to: file)
        var total = try await reader.recordedTotal(provider: "claude", target: target); XCTAssertEqual(total, 105)
        let appended = Data((#"{"type":"assistant","message":{"id":"a","usage":{"input_tokens":100,"output_tokens":10}}}"# + "\n" + #"{"type":"assistant","message":{"id":"b","usage":{"input_tokens":20,"output_tokens":3}}}"# + "\n").utf8)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: appended); try handle.close()
        total = try await reader.recordedTotal(provider: "claude", target: target); XCTAssertEqual(total, 133)
        let bytes = await reader.bytesRead(); XCTAssertEqual(bytes, first.count + appended.count)
    }

    func testClaudeChangingRequestIDCountsStableMessageOnceAndMigratesLedger() async throws {
        let rows = try [#"{"type":"assistant","message":{"id":"a","usage":{"input_tokens":100,"output_tokens":55}}}"#,
            #"{"type":"assistant","requestId":"r","message":{"id":"a","usage":{"input_tokens":100,"output_tokens":60}}}"#,
            #"{"type":"assistant","requestId":"r2","message":{"id":"a","usage":{"input_tokens":100,"output_tokens":70}}}"#]
            .map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        XCTAssertEqual(BackendAGOPTTokenUsage.total(provider: "claude", rows: rows), 170)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-claude-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let ledger = BackendAGOPTTokenLedger(persistence: persistence)
        _ = try await ledger.observe(key: "exact-conversation", amounts: [":a":155, "r:a":160])
        let merged = try await ledger.observe(key: "exact-conversation", amounts: ["message:a":170, "message:b":20], claudeMessageIDs: ["a", "b"])
        XCTAssertEqual(merged, 190)
        let restarted = BackendAGOPTTokenLedger(persistence: persistence)
        let again = try await restarted.observe(key: "exact-conversation", amounts: ["message:a":170, "message:b":20], claudeMessageIDs: ["a", "b"])
        XCTAssertEqual(again, 190)
    }
    func testRewrittenGeminiMessagesKeepSpentTokensAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root.appendingPathComponent("remote"), ownership: .exclusive)
        let file = root.appendingPathComponent("conversation.json")
        let target = BackendTaskTranscriptTarget(path: file.path, roots: [root.path])
        func write(_ messages: [(String, Double)]) throws {
            let rows = messages.map { id, count in NativeRPCValue.object([.init("type", .string("gemini")), .init("id", .string(id)), .init("tokens", .object([.init("total", .number(count))]))]) }
            try NativeRPCValue.object([.init("messages", .array(rows))]).encodedJSON().write(to: file, options: .atomic)
        }
        let reader = BackendAGOPTTokenUsage(locate: { _ in target }, persistence: persistence)
        try write([("a", 100), ("b", 100)])
        let first = try await reader.recordedTotal(provider: "gemini", target: target); XCTAssertEqual(first, 200)
        try write([("a", 100), ("c", 20)])
        let rewind = try await reader.recordedTotal(provider: "gemini", target: target); XCTAssertEqual(rewind, 220)
        let restarted = BackendAGOPTTokenUsage(locate: { _ in target }, persistence: persistence)
        try write([("a", 100), ("d", 30)])
        let afterRestart = try await restarted.recordedTotal(provider: "gemini", target: target); XCTAssertEqual(afterRestart, 250)
        let again = try await restarted.recordedTotal(provider: "gemini", target: target); XCTAssertEqual(again, 250)
    }
    func testFullLedgerDropsLeastRecentlyUpdatedConversationInsteadOfRefusing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-ledger-full-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        func saved() throws -> Set<String> {
            Set(try XCTUnwrap(persistence.read("agopt-token-usage.json", maximumBytes: 4 * 1024 * 1024))["conversations"].fields?.map(\.key) ?? [])
        }
        try persistence.write("agopt-token-usage.json", value: NativeRPCValue.parseJSON(Data(#"{"version":1,"conversations":{"old-a":{"m":1},"old-b":{"m":2},"old-c":{"m":3}}}"#.utf8)))
        let ledger = BackendAGOPTTokenLedger(persistence: persistence, maximumConversations: 3)
        let updated = try await ledger.observe(key: "old-b", amounts: ["m": 5]); XCTAssertEqual(updated, 5)
        let fresh = try await ledger.observe(key: "new-d", amounts: ["m": 10]); XCTAssertEqual(fresh, 10)
        XCTAssertEqual(try saved(), ["old-b", "old-c", "new-d"])
        let restarted = BackendAGOPTTokenLedger(persistence: persistence, maximumConversations: 3)
        _ = try await restarted.observe(key: "new-d", amounts: ["m": 12])
        _ = try await restarted.observe(key: "new-e", amounts: ["m": 1])
        XCTAssertEqual(try saved(), ["old-b", "new-d", "new-e"])
        _ = try await restarted.observe(key: "new-f", amounts: ["m": 1])
        XCTAssertEqual(try saved(), ["new-d", "new-e", "new-f"])
    }
    func testExactTranscriptChangesEmitAnEventWithoutStatusPolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-events-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversation.json")
        try Data(#"{"messages":[{"type":"gemini","id":"a","tokens":{"total":10}}]}"#.utf8).write(to: file)
        let target = BackendTaskTranscriptTarget(path: file.path, roots: [root.path])
        let reader = BackendAGOPTTokenUsage(locate: { _ in target })
        let meta = try JSONDecoder().decode(BackendSessionMeta.self, from: Data(#"{"id":"stub","cwd":"/tmp","title":"Stub","provider":"gemini","createdAt":1,"resumed":false}"#.utf8))
        let changed = expectation(description: "real vnode change")
        let observation = try await reader.observe(meta, onChange: { changed.fulfill() })
        let stop = try XCTUnwrap(observation); defer { stop() }
        try Data(#"{"messages":[{"type":"gemini","id":"a","tokens":{"total":20}}]}"#.utf8).write(to: file, options: .atomic)
        await fulfillment(of: [changed], timeout: 5)
        let total = try await reader.total(meta); XCTAssertEqual(total, 20)
    }
}
