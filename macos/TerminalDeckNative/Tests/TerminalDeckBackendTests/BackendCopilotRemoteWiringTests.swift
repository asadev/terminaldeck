import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Remote Hoot transcript wiring")
struct BackendCopilotRemoteWiringTests: Sendable {
    @Test func namedTranscriptNeverReadsNewestDeskConversationAndEventsAppendParsedChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotRemoteChat-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = NativeTranscriptScope(configDirectory: root.appendingPathComponent(".claude").path)
        let cwd = root.appendingPathComponent("hoot").path
        let directory = try #require(NativeTranscriptPaths.projectDirectories(cwd, scope: scope).first)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let desk = URL(fileURLWithPath: directory).appendingPathComponent("desk.jsonl")
        try Data("{\"type\":\"assistant\",\"uuid\":\"desk\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"private desktop conversation\"}]}}\n".utf8).write(to: desk)
        let recorder = BackendCopilotRemoteTestRecorder()
        let watcher = BackendCopilotRemoteChatWatcher(cwd: cwd, agentSessionID: "phone", scope: scope) { update in
            if let frame = try? BackendRemoteServerMessage(.copilotChat, fields: [.init("run", .string("phone")), .init("messages", .array(update.messages))]) { await recorder.receive(frame) }
        }
        try await watcher.start()
        #expect(await recorder.all(.copilotChat).isEmpty)
        let named = URL(fileURLWithPath: directory).appendingPathComponent("phone.jsonl")
        try Data("{\"type\":\"assistant\",\"uuid\":\"phone\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"PONG\"}]}}\n".utf8).write(to: named)
        let frame = await recorder.next(.copilotChat)
        #expect(frame.value["messages"].elements?.first?["text"].string == "PONG")
        #expect(!frame.value.compact.contains("private desktop conversation"))
        await watcher.stop()
    }
}
