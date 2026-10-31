import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U140 (#194, #341, #361, #362): the task engine answers from what it already read, and never from a stale copy.
@Suite("U140 task engine speed")
struct TaskEngineSpeedTests {
    @Test func keptInstructionsAreReadAgainAfterAnyEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("u140-instructions-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let config = try BackendTaskConfiguration(persistence: try BackendTaskPersistence(directory: root, ownership: .exclusive)); try await config.start()
        _ = try await config.saveAgent(.object([.init("id", .string("builder")), .init("name", .string("Builder")), .init("instructions", .string("Alpha one."))]))
        let file = root.appendingPathComponent("agent-instructions/builder.md")
        let written = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        for _ in 0..<2 { #expect(try await config.agent("builder")?["instructions"].string == "Alpha one.") }
        // Same size, same file, the old modification time put back: the change time still tells.
        try Data("Bravo two.\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
        #expect(try await config.agent("builder")?["instructions"].string == "Bravo two.")
        #expect(try await config.allAgents().first?["instructions"].string == "Bravo two.")
        try FileManager.default.removeItem(at: file)
        let gone = try #require(try await config.agent("builder"))
        #expect(gone["instructionsFile"] == .null)
        #expect(gone["instructions"].string != "Bravo two.")
    }

    @Test func checklistAndFieldCallsFindTheirOwnTask() async throws {
        let clock = BackendCrmTaskClockParityVirtualClock()
        clock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        clock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(clock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), first = try await f.make("First"), second = try await f.make("Second")
            let listA = try #require(await f.call("addChecklist", .string(first), .null)["id"].string)
            let itemA = try #require(await f.call("addChecklistItem", .string(listA), .string("One"))["id"].string)
            _ = try await f.ok("setChecklistItemDone", .string(itemA), .bool(true))
            // Made after the first task's parts were learned: found on its own task, not missed.
            let listB = try #require(await f.call("addChecklist", .string(second), .null)["id"].string)
            let itemB = try #require(await f.call("addChecklistItem", .string(listB), .string("Two"))["id"].string)
            _ = try await f.ok("setChecklistItemDone", .string(itemB), .bool(true))
            _ = try await f.ok("renameChecklist", .string(listB), .string("Errands"))
            #expect(crmParityMatches(await f.bundle(first)["checklists"].elements?.first?["items"].elements?.first ?? .missing, crmParityValue(["title": "One", "done": true])))
            let shown = await f.bundle(second)["checklists"].elements?.first ?? .missing
            #expect(shown["title"].string == "Errands")
            #expect(crmParityMatches(shown["items"].elements?.first ?? .missing, crmParityValue(["title": "Two", "done": true])))
            // A part that left its task is not found on the task it was last seen on.
            _ = try await f.ok("deleteChecklist", .string(listA))
            #expect(crmParityEqual(await f.call("setChecklistItemDone", .string(itemA), .bool(false)), crmParityFailure("Checklist item not found")))
            #expect(crmParityEqual(await f.call("renameChecklist", .string(listA), .string("x")), crmParityFailure("Checklist not found")))
            let field = try await f.ok("createTaskField", .string(second), crmParityValue(["label": "Qty", "kind": "number"]))["field"]["id"]
            #expect(await f.call("updateTaskFieldValue", field, .number(3))["field"]["value"] == .number(3))
            _ = try await f.ok("deleteTaskField", field)
            #expect(crmParityEqual(await f.call("updateTaskFieldValue", field, .number(4)), crmParityFailure("Field not found")))
        }
    }

    @Test func sessionLookupFollowsClaimsAndReleases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("u140-sessions-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendTaskStore(persistence: try BackendTaskPersistence(directory: root, ownership: .memory)); try await store.start()
        func row(_ id: String) -> NativeRPCValue { .object([.init("id", .string("local:" + id)), .init("keyId", .string("local")), .init("externalTaskId", .string(id)), .init("local", .bool(true))]) }
        _ = try await store.put(row("a")); _ = try await store.put(row("b"))
        #expect(try await store.bySession("s1") == nil)
        #expect(try await store.claim("local:a", sessionID: "s1", liveSessionIDs: []))
        #expect(try await store.bySession("s1")?.id == "local:a")
        try await store.release("local:a")
        #expect(try await store.bySession("s1") == nil)
        #expect(try await store.claim("local:b", sessionID: "s1", liveSessionIDs: []))
        #expect(try await store.bySession("s1")?.id == "local:b")
        try await store.moveToTrash("local:b")
        #expect(try await store.bySession("s1") == nil)
    }
}
