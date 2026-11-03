import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct PCProgressContextTests {
    func row(_ notes: [NativeRPCValue] = []) throws -> BackendTaskRecord {
        try .init(.object([.init("id", .string("local:one")), .init("keyId", .string("local")), .init("externalTaskId", .string("one")), .init("local", .bool(true)), .init("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("worker"))])), .init("sessionId", .string("session")), .init("agoptRunID", .string("run")), .init("notes", .array(notes))]))
    }
    func note(_ id: String, _ text: String, at: Double = 1) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("text", .string(text)), .init("by", .string("worker")), .init("kind", .string("progress")), .init("at", .number(at))])
    }
    @Test func retryAndRestartRetainOneReceiptAndRejectDifferentBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let store = BackendTaskStore(persistence: persistence); try await store.start(); _ = try await store.put(row().value)
        #expect(try await store.progressOnce("local:one", by: "worker", text: "Saved the draft", eventID: "event-1"))
        let reopened = BackendTaskStore(persistence: persistence); try await reopened.start()
        #expect(try await !reopened.progressOnce("local:one", by: "worker", text: "Saved the draft", eventID: "event-1"))
        await #expect(throws: NativeRPCError.self) { _ = try await reopened.progressOnce("local:one", by: "worker", text: "Different result", eventID: "event-1") }
        #expect(try await reopened.byID("local:one")?.value["notes"].elements?.count == 1)
        _ = try await reopened.update("local:one", patch: .object([.init("agoptRunID", .string("another-run"))]))
        #expect(try await reopened.progressOnce("local:one", by: "worker", text: "Saved the draft", eventID: "event-1"))
    }
    @Test func deltaDetectsEditsAndDoesNotAcknowledgeOmittedMessages() throws {
        let task = try row([note("a", "First"), note("b", "Second", at: 2)])
        let first = BackendPCContextDelta.make(task, limit: 1)
        #expect(first.text.contains("First")); #expect(first.text.contains("1 more")); #expect(first.text.contains("untrusted"))
        let delivered = try BackendTaskRecord(task.value.setting("pcDeliveredContext", first.cursor))
        let second = BackendPCContextDelta.make(delivered)
        #expect(second.text.contains("Second")); #expect(!second.text.contains("First"))
        let changed = try BackendTaskRecord(delivered.value.setting("notes", .array([note("a", "Edited without changing timestamp"), note("b", "Second", at: 2)])))
        #expect(BackendPCContextDelta.make(changed).text.contains("Edited without changing timestamp"))
    }
    @Test func changedRecipientGetsContextAndClippedUnicodeStaysPending() throws {
        let original = try row([note("a", "First")])
        let sent = BackendPCContextDelta.make(original)
        let other = try BackendTaskRecord(original.value.setting("pcDeliveredContext", sent.cursor).setting("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("other"))])))
        #expect(BackendPCContextDelta.make(other).text.contains("First"))
        let long = try row([note("long", String(repeating: "😀", count: 500))])
        let clipped = BackendPCContextDelta.make(long)
        #expect(clipped.text.contains("shortened"))
        let next = try BackendTaskRecord(long.value.setting("pcDeliveredContext", clipped.cursor))
        #expect(!BackendPCContextDelta.make(next).text.isEmpty)
    }
    @Test func staleDeliveryDoesNotAcknowledgeAnotherRun() async throws {
        let persistence = try BackendTaskPersistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), ownership: .memory)
        let store = BackendTaskStore(persistence: persistence); try await store.start()
        let expected = try row([note("a", "Only evidence")]); _ = try await store.put(expected.value)
        _ = try await store.update(expected.id, patch: .object([.init("agoptRunID", .string("new-run"))]))
        try await store.acknowledgeContext(expected.id, packet: BackendPCContextDelta.make(expected), expected: expected)
        #expect(try await store.byID(expected.id)?.value["pcDeliveredContext"].isNullish == true)
    }
    @Test func equalTimestampsKeepRecordedMessageOrderAcrossContinuationBatches() throws {
        let task = try row([note("n-started", "Builder started on this."), note("n-question", "Allow this edit?").setting("kind", .string("question"))])
        let packet = BackendPCContextDelta.make(task)
        let started = try #require(packet.text.range(of: "Builder started on this."))
        let question = try #require(packet.text.range(of: "Allow this edit?"))
        #expect(started.lowerBound < question.lowerBound)
        let first = BackendPCContextDelta.make(task, limit: 1)
        #expect(first.text.contains("Builder started on this."))
        #expect(!first.text.contains("Allow this edit?"))
        let acknowledged = try BackendTaskRecord(task.value.setting("pcDeliveredContext", first.cursor))
        let second = BackendPCContextDelta.make(acknowledged, limit: 1)
        #expect(second.text.contains("Allow this edit?"))
        #expect(!second.text.contains("Builder started on this."))
    }

}
