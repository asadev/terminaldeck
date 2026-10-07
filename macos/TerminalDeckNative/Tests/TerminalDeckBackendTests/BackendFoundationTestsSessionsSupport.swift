import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Only throwaway files are opened by the foundation test port.
final class BackendFoundationTestsSessionsScratch {
    let root: URL
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-foundation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory.resolvingSymlinksInPath()
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func write(_ relative: String, _ text: String) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }
    func append(_ file: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    func modified(_ file: URL, milliseconds: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: milliseconds / 1000)], ofItemAtPath: file.path)
    }
}

enum BackendFoundationTestsSessionsFixtures {
    static let conversation = "a365c25c-ac46-4297-99f9-4beca7005eef"
    static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    static func line(_ overrides: [String: Any]) throws -> String {
        var value: [String: Any] = ["parentUuid": NSNull(), "isSidechain": false,
            "userType": "external", "cwd": "/Users/apple/Projects/terminaldeck",
            "sessionId": conversation, "version": "2.1.209", "gitBranch": "main"]
        value.merge(overrides) { _, newer in newer }; return try json(value)
    }
    static func prompt(_ text: String, overrides: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = ["type": "user", "promptId": "p-1",
            "message": ["role": "user", "content": text], "uuid": "u-prompt-1",
            "timestamp": "2026-08-12T09:00:00.000Z", "permissionMode": "default",
            "origin": ["kind": "human"], "promptSource": "sdk", "entrypoint": "claude-desktop"]
        value.merge(overrides) { _, newer in newer }; return try line(value)
    }
    static func reply(_ text: String, overrides: [String: Any] = [:], messageOverrides: [String: Any] = [:]) throws -> String {
        var message: [String: Any] = ["id": "msg_A", "role": "assistant", "model": "claude-opus-5",
            "content": [["type": "text", "text": text]],
            "usage": ["input_tokens": 4, "output_tokens": 120, "cache_read_input_tokens": 51000]]
        message.merge(messageOverrides) { _, newer in newer }
        var value: [String: Any] = ["type": "assistant", "uuid": "u-reply-1",
            "timestamp": "2026-08-12T09:00:04.000Z", "requestId": "req_1", "message": message]
        value.merge(overrides) { _, newer in newer }; return try line(value)
    }
    static func toolResult(_ id: String, _ output: String) throws -> String {
        try line(["type": "user", "parentUuid": "u-reply-1", "promptId": "p-1",
            "message": ["role": "user", "content": [["tool_use_id": id, "type": "tool_result", "content": output]]],
            "uuid": "u-result-" + id, "timestamp": "2026-08-12T09:00:06.000Z", "toolUseResult": ["stdout": output]])
    }
    static func messages(_ lines: [String]) async throws -> [ChatMessage] {
        let scratch = try BackendFoundationTestsSessionsScratch()
        let file = try scratch.write(conversation + ".jsonl", lines.joined(separator: "\n") + "\n")
        let reader = NativeChatTranscriptReader(path: file.path, allowedRoots: [scratch.root.path])
        return try await reader.readAll(wholeConversation: true).messages
    }
    static func meta(_ id: String, cwd: String = "/w/app", provider: String = "claude", exited: Bool = false,
                     conversation: String? = nil) -> BackendSessionMeta {
        let input = BackendCreateSessionInput(cwd: cwd, provider: provider)
        var result = BackendSessionMeta(id: id, input: input, spawn: .init(provider: provider,
            command: "/fixture/" + provider, args: [], path: "/fixture", agentSessionId: conversation),
            now: Date(timeIntervalSince1970: 1))
        if exited { result.exitCode = 0 }; return result
    }
}
