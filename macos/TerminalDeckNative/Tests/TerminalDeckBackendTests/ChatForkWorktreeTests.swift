import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatForkWorktreeTests: XCTestCase, @unchecked Sendable {
    private func meta(_ id: String, cwd: String = "/project", provider: String = "codex", profile: String = "account", home: String? = nil) -> BackendSessionMeta {
        var input = BackendCreateSessionInput(cwd: cwd, provider: provider)
        input.chat = true
        return BackendSessionMeta(id: id, input: input, spawn: .init(provider: provider, command: "/unused", args: [], path: "", env: [:],
            profile: .init(id: profile, name: profile), homeProfileId: home))
    }
    private var relationship: BackendChatForkWorktree {
        .init(key: "chat-created-worktree", sessionID: "child", parentSessionID: "parent", folder: "/app/worktrees/child")
    }
    func testExactCodexBoundarySeedsSameFolderAndRecordedWorktreeWithoutLaterTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fork-worktree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try BackendHootChatStore(file: directory.appendingPathComponent("source.json"), provider: .codex)
        let records: [HootChatRecord] = [.text(.user, "keep request"), .text(.message, id: "answer-first", "keep answer"),
            .init(.completed, value: .object([.init("id", .string("provider-first"))])), .text(.user, "later request"),
            .text(.message, id: "answer-later", "later answer"), .init(.completed, value: .object([.init("id", .string("provider-later"))]))]
        let events = records.enumerated().map { index, record in
            HootChatEvent(conversationID: "original", turnID: index < 3 ? "first" : "later", sequence: index + 1, provider: .codex, record: record)
        }
        try await source.seedForkHistory(events)
        let original = await source.snapshot(limit: 100)
        let rows = await source.messageActionRows
        let mapped = await source.forkTurnIDs()
        let calls = BackendDeckCoreSecurityTestBox<[NativeRPCValue]>([])
        for (index, worktree) in [nil, relationship].enumerated() {
            let target = meta("child", cwd: worktree?.folder ?? "/project")
            let plan = try await BackendChatFork.invoke(operation: "fork/create", args: .object([.init("throughSequence", .number(2))]), provider: .codex,
                conversation: "original", cwd: "/project", knownTurns: mapped, quiet: true, request: { _, _ in XCTFail("Must use isolated provider"); return .null },
                isolatedFork: { params in
                    calls.edit { $0.append(params) }
                    return .object([.init("thread", .object([.init("id", .string("forked")), .init("forkedFromId", .string("original"))]))])
                }, knownMessages: rows)
            XCTAssertEqual(plan["conversationId"].string, "forked")
            let destination = try BackendHootChatStore(file: directory.appendingPathComponent("child-\(index).json"), provider: .codex)
            try await BackendChatForkHistory.seed(parent: meta("parent"), target: target, worktree: worktree, through: 2, source: source, destination: destination)
            let copied = await destination.snapshot(limit: 100)
            XCTAssertEqual(copied["events"].elements?.count, 3, "Exact Codex fork includes the completion receipt, excludes the later turn")
            XCTAssertEqual(copied["events"].elements?[1]["value"]["text"].string, "keep answer")
            XCTAssertNotEqual(copied["conversationId"].string, original["conversationId"].string)
            let reopened = try BackendHootChatStore(file: directory.appendingPathComponent("child-\(index).json"), provider: .codex)
            let restored = await reopened.snapshot(limit: 100)
            XCTAssertEqual(restored["events"], copied["events"])
        }
        XCTAssertEqual(calls.get().map { $0["lastTurnId"].string }, ["provider-first", "provider-first"])
        let unchanged = await source.snapshot(limit: 100)
        XCTAssertEqual(unchanged["events"], original["events"])
    }
    func testWorktreeRelationshipCannotChangeSourceTargetFolderAIOrAccount() throws {
        let parent = meta("parent"), target = meta("child", cwd: relationship.folder)
        XCTAssertThrowsError(try BackendChatForkHistory.authorize(parent: parent, target: target, worktree: nil))
        XCTAssertNoThrow(try BackendChatForkHistory.authorize(parent: parent, target: target, worktree: relationship))
        for wrong in [
            BackendChatForkWorktree(key: "key", sessionID: "different", parentSessionID: "parent", folder: target.cwd),
            .init(key: "key", sessionID: "child", parentSessionID: "different", folder: target.cwd),
            .init(key: "key", sessionID: "child", parentSessionID: "parent", folder: "/other"),
            .init(key: "", sessionID: "child", parentSessionID: "parent", folder: target.cwd)
        ] { XCTAssertThrowsError(try BackendChatForkHistory.authorize(parent: parent, target: target, worktree: wrong)) }
        for wrong in [meta("child", cwd: target.cwd, provider: "claude"), meta("child", cwd: target.cwd, profile: "different"),
                      meta("child", cwd: target.cwd, home: "different")] {
            XCTAssertThrowsError(try BackendChatForkHistory.authorize(parent: parent, target: wrong, worktree: relationship))
        }
        XCTAssertThrowsError(try BackendChatForkHistory.authorize(parent: meta("parent", provider: "claude"), target: meta("child", cwd: target.cwd, provider: "claude"), worktree: relationship))
        XCTAssertThrowsError(try BackendChatForkHistory.authorize(parent: parent, target: parent, worktree: relationship))
        let wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(relationship))
        let decoded = try JSONDecoder().decode(BackendChatForkWorktree.self, from: wire.encodedJSON())
        XCTAssertNoThrow(try BackendChatForkHistory.authorize(parent: parent, target: target, worktree: decoded), "Authenticated keeper route retains the recorded relationship")
    }
    func testInvalidBoundaryLeavesDestinationHistoryEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fork-invalid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try BackendHootChatStore(file: root.appendingPathComponent("source.json"), provider: .codex)
        let destination = try BackendHootChatStore(file: root.appendingPathComponent("child.json"), provider: .codex)
        do {
            try await BackendChatForkHistory.seed(parent: meta("parent"), target: meta("child", cwd: relationship.folder), worktree: relationship,
                through: 99, source: source, destination: destination)
            XCTFail("Foreign boundary must fail before copying")
        } catch { XCTAssertNotNil(error as? NativeRPCError) }
        let result = await destination.snapshot()
        XCTAssertEqual(result["events"].elements?.count, 0)
    }
}
