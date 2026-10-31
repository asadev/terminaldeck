import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct ChatDeliveryDeletionTests {
    @Test func deletionRemovesContentsPreservesOtherChatsAndHoldsDelayedRetries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-delete-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for registry in ["chat-outgoing", "delivery-requests"] {
            let directory = root.appendingPathComponent(registry)
            let queue = BackendChatDeliveryQueue(directory: directory)
            func message(_ chat: String, _ id: String) -> NativeRPCValue {
                .object([.init("id", .string(chat)), .init("clientMessageId", .string(id)),
                         .init("text", .string("private message")), .init("attachments", .array([.string("private picture")]))])
            }
            let confirmed = message("deleted", "confirmed"), pending = message("deleted", "pending")
            let fallback = message("deleted", "retry-request:private-fingerprint")
            let resolved = try queue.claim(fallback).message
            #expect(try !queue.begin(confirmed))
            try queue.finish(confirmed)
            #expect(try !queue.begin(pending))
            let other = message("kept", "other")
            #expect(try !queue.begin(other))
            try queue.finish(other)
            try queue.forgetConversation("deleted")
            try queue.forgetConversation("deleted")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let messages = try files.filter { $0.pathExtension == "json" }.map { try NativeRPCValue.parseJSON(Data(contentsOf: $0))["message"] }
            #expect(messages == [other])
            let reopened = BackendChatDeliveryQueue(directory: directory)
            for old in [confirmed, pending, resolved] {
                #expect(throws: (any Error).self) { try reopened.begin(old) }
                #expect(throws: (any Error).self) { try reopened.finish(old) }
            }
            #expect(throws: (any Error).self) { try reopened.claim(fallback) }
            #expect(try reopened.begin(other))
            #expect(try !reopened.begin(message("deleted", "new-identity")))
        }
    }
    @Test func deletingUnusedRegistryDoesNotCreateIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-unused-" + UUID().uuidString)
        try BackendChatDeliveryQueue(directory: directory).forgetConversation("unused")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
