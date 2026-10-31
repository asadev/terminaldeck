import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U141 (#182): the task records are written in three files, each only when its part changed; a burst of routine
/// changes is written once; the Trash ages out after 30 days.
@Suite("U141 task store files")
struct TaskStoreFilesTests {
    private static func folder(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("u141-\(name)-" + UUID().uuidString) }
    private static func row(_ id: String, _ extra: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        .object([.init("id", .string("local:" + id)), .init("keyId", .string("local")), .init("externalTaskId", .string(id)), .init("local", .bool(true)), .init("title", .string(id))] + extra.map { .init($0.0, $0.1) })
    }
    private static func inode(_ url: URL) throws -> Int { try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue) }
    private static func titles(_ value: NativeRPCValue?) -> [String] { (value?["tasks"].elements ?? []).compactMap { $0["title"].string } }

    @Test func eachPartHasItsOwnFileWrittenOnlyWhenItChanged() async throws {
        let root = Self.folder("parts"); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let store = BackendTaskStore(persistence: persistence); try await store.start()
        _ = try await store.put(Self.row("a"))
        try await store.putAgentRun(.object([.init("id", .string("run-1")), .init("agent_id", .string("builder")), .init("session_id", .string("s1")), .init("started_at", .number(1))]))
        try await store.markOurs(keyID: "crm", eventID: "e1")
        let tasksFile = try #require(try persistence.read("tasks.json"))
        #expect(!tasksFile.has("agentRuns") && !tasksFile.has("seen") && !tasksFile.has("ours"))
        #expect(try persistence.read(BackendTaskStore.runsFile)?["agentRuns"].elements?.first?["id"].string == "run-1")
        #expect(try persistence.read(BackendTaskStore.receiptsFile)?["ours"].elements?.first?.elements?.first?.string == "crm:e1")
        let runs = root.appendingPathComponent(BackendTaskStore.runsFile), receipts = root.appendingPathComponent(BackendTaskStore.receiptsFile)
        let before = (try Self.inode(runs), try Self.inode(receipts))
        _ = try await store.update("local:a", patch: .object([.init("title", .string("A2"))]))
        #expect(Self.titles(try persistence.read("tasks.json")) == ["A2"])
        #expect(try Self.inode(runs) == before.0 && Self.inode(receipts) == before.1)
        let reopened = BackendTaskStore(persistence: persistence); try await reopened.start()
        #expect(try await reopened.agentRun("run-1") != nil)
        #expect(try await reopened.isOurs(keyID: "crm", eventID: "e1"))
        #expect(try await reopened.byID("local:a")?.value["title"].string == "A2")
    }

    @Test func anOldTasksFileGivesUpRunsAndReceiptsOnlyAfterTheirFilesHoldThem() async throws {
        let root = Self.folder("migrate"); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive), now = Date().timeIntervalSince1970 * 1_000
        try persistence.write("tasks.json", value: .object([.init("v", .number(1)), .init("tasks", .array([Self.row("a")])), .init("trash", .array([])),
            .init("agentRuns", .array([.object([.init("id", .string("run-old")), .init("agent_id", .string("builder")), .init("session_id", .string("s0")), .init("started_at", .number(5))])])),
            .init("agentRuntimeState", .object([.init("builder", .object([.init("pause_reason", .string("manual"))]))])), .init("agentHistorySince", .number(5)),
            .init("seen", .array([.array([.string("crm:e0"), .object([.init("at", .number(now)), .init("answer", .string("ok"))])])])), .init("ours", .array([.array([.string("crm:o0"), .number(now)])]))]))
        let store = BackendTaskStore(persistence: persistence); try await store.start()
        #expect(try await store.agentRun("run-old") != nil)
        _ = try await store.update("local:a", patch: .object([.init("title", .string("A2"))]))
        let tasksFile = try #require(try persistence.read("tasks.json"))
        #expect(!tasksFile.has("agentRuns") && !tasksFile.has("seen") && !tasksFile.has("ours") && Self.titles(tasksFile) == ["A2"])
        let reopened = BackendTaskStore(persistence: persistence); try await reopened.start()
        #expect(try await reopened.agentRun("run-old") != nil)
        #expect(try await reopened.agentRuntime("builder")["pause_reason"].string == "manual")
        #expect(try await reopened.answered(keyID: "crm", eventID: "e0") == .string("ok"))
        #expect(try await reopened.isOurs(keyID: "crm", eventID: "o0"))
    }

    @Test func aBurstIsWrittenOnceAndUrgentChangesAtOnce() async throws {
        let root = Self.folder("burst"); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let store = BackendTaskStore(persistence: persistence, writeDelay: 300); try await store.start()
        _ = try await store.put(Self.row("a"))
        #expect(Self.titles(try persistence.read("tasks.json")) == ["a"])
        _ = try await store.put(Self.row("b"))
        #expect(Self.titles(try persistence.read("tasks.json")) == ["a"])
        // Taking a session is written at once, with what was waiting.
        #expect(try await store.claim("local:a", sessionID: "s1", liveSessionIDs: []))
        let claimed = try persistence.read("tasks.json")
        #expect(Self.titles(claimed) == ["a", "b"] && claimed?["tasks"].elements?.first?["sessionId"].string == "s1")
        _ = try await store.update("local:b", patch: .object([.init("title", .string("B2"))]))
        #expect(Self.titles(try persistence.read("tasks.json")) == ["a", "b"])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(Self.titles(try persistence.read("tasks.json")) == ["a", "B2"])
        _ = try await store.update("local:b", patch: .object([.init("title", .string("B3"))]))
        _ = try await store.update("local:b", patch: .object([.init("title", .string("B4"))]))
        try await store.stop()
        #expect(Self.titles(try persistence.read("tasks.json")) == ["a", "B4"])
    }

    @Test func localTasksLeaveTheTrashAfterThirtyDays() async throws {
        let root = Self.folder("trash"); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive), now = Date().timeIntervalSince1970 * 1_000, day = 86_400_000.0
        let crm = NativeRPCValue.object([.init("id", .string("crm:x")), .init("keyId", .string("crm")), .init("externalTaskId", .string("x")), .init("deletedAt", .number(now - 40 * day))])
        try persistence.write("tasks.json", value: .object([.init("v", .number(1)), .init("tasks", .array([Self.row("live")])), .init("trash", .array([
            Self.row("old", [("deletedAt", .number(now - 31 * day))]), Self.row("recent", [("deletedAt", .number(now - day))]),
            Self.row("held", [("deletedAt", .number(now - 31 * day)), ("sessionId", .string("s9"))]), crm]))]))
        let store = BackendTaskStore(persistence: persistence); try await store.start()
        #expect(try await store.inTrash().map(\.id) == ["local:recent", "local:held", "crm:x"])
        _ = try await store.update("local:live", patch: .object([.init("title", .string("Live"))]))
        #expect((try persistence.read("tasks.json")?["trash"].elements ?? []).compactMap { $0["id"].string } == ["local:recent", "local:held", "crm:x"])
    }
}
