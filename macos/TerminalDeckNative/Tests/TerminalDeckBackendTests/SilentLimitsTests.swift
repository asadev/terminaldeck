import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U20: a limit refuses or archives with a reason; it never quietly deletes or drops what was there.
@Suite("Silent limits never delete or drop data")
struct SilentLimitsTests {
    /// #590: with 500 settings saved, a new one is refused with a reason instead of being dropped while the save says yes.
    @Test func aFullSettingsFileRefusesTheNewSetting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-limits-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object((0..<BackendAppSettingsStore.maxKeys).map { .init("k\($0)", .number(Double($0))) }))
        await #expect(throws: NativeRPCError.self) { try await store.patch(.object([.init("new", .bool(true))])) }
        // Changing or removing one that is already there still works.
        let changed = try await store.patch(.object([.init("k0", .number(-1)), .init("k1", .null)]))
        #expect(changed["values"]["k0"] == .number(-1) && !changed["values"].has("k1"))
        #expect(try await store.patch(.object([.init("new", .bool(true))]))["values"]["new"] == .bool(true))
    }

    /// #343: at 1,000 comments a new one is refused; the oldest is never deleted, and details of comments an older
    /// build dropped are pruned with the next save.
    @Test func aFullCommentThreadRefusesAndOrphansArePruned() async throws {
        let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Long thread")
        let rows = (0..<(BackendTaskDetailService.maxComments - 1)).map { NativeRPCValue.object([.init("id", .string("c\($0)")), .init("authorUserId", .string("me")), .init("body", .string("n\($0)")), .init("at", .number(Double($0)))]) }
        let task = try await f.row(id)
        let detail = (task["detail"].fields == nil ? NativeRPCValue.object([]) : task["detail"]).setting("comments", .array(rows))
            .setting("commentMeta", .object([.init("gone", .object([.init("resolvedBy", .string("me"))]))]))
            .setting("reactions", .object([.init("gone", .array([])), .init("c0", .array([.object([.init("emoji", .string("👍")), .init("userIds", .array([.string("me")]))])]))]))
        _ = try await f.store.put(task.setting("detail", detail))
        _ = try await f.ok("addTaskComment", .string(id), .string("The thousandth"))
        let saved = try await f.row(id)["detail"]
        #expect(saved["comments"].elements?.count == BackendTaskDetailService.maxComments && saved["comments"].elements?.first?["id"].string == "c0")
        #expect(!saved["commentMeta"].has("gone") && !saved["reactions"].has("gone") && saved["reactions"].has("c0"))
        let refused = await f.call("addTaskComment", .string(id), .string("One too many"))
        #expect(refused["ok"].bool == false && refused["error"].string?.contains("1000 comments") == true)
        #expect(try await f.row(id)["detail"]["comments"].elements?.count == BackendTaskDetailService.maxComments)
    }

    /// #345: past 500 open CRM tasks the oldest idle one is archived with a note, not deleted, and later CRM updates still reach it.
    @Test func crmTasksPastTheLimitAreArchivedNotDeleted() async throws {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/private/tmp/td-limits-inert"), ownership: .memory)
        let store = BackendTaskStore(persistence: persistence)
        try await store.start()
        for n in 0...500 {
            _ = try await store.put(.object([.init("id", .string("crm:t\(n)")), .init("keyId", .string("crm")), .init("externalTaskId", .string("t\(n)")),
                                             .init("title", .string("CRM task \(n)")), .init("project", .string(""))]))
        }
        let all = try await store.all()
        #expect(all.count == 501)
        let archived = all.filter { !$0.value["archivedAt"].isNullish }
        #expect(archived.count == 1)
        let one = try #require(archived.first)
        #expect(one.value["notes"].elements?.last?["text"].string?.contains("Nothing was deleted") == true)
        _ = try await store.update(one.id, patch: .object([.init("crmStatus", .string("Done"))]))
        #expect(try await store.byID(one.id)?.value["crmStatus"].string == "Done")
    }
}
