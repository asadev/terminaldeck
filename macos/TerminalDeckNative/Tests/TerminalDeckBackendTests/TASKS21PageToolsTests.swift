import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite struct TASKS21PageToolsTests {
    private func rig() async throws -> BackendCrmTaskToolsParityFixture {
        let rig = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
        let authority = BackendTaskToolAuthority(requireTasks: { caller in
            if caller.machineID == "denied" { throw NativeRPCError(code: "not-granted", message: "No tasks access") }
        }, requireHoot: { _ in }, visible: { caller, row in caller.projectRoot == nil || row.project == caller.projectRoot },
            project: { caller, path in
                if let root = caller.projectRoot, root != path { throw NativeRPCError.invalidArguments("Outside project") }
            }, authorize: { _, _, _, tier in await rig.audit.record(tier) }, actorName: { _ in "test" })
        try await BackendTasksPageTools.install(server: rig.server, ownerID: "tasks21-test", authority: authority,
            store: rig.f.store, local: rig.f.local, views: { args in .object([.init("action", args["do"])]) })
        return rig
    }
    private func call(_ rig: BackendCrmTaskToolsParityFixture, _ id: String, _ args: [String: Any],
                      folder: String? = nil, tiers: Set<BackendMCPTier> = [.read, .alter], caller: String = "hoot") async throws -> NativeRPCValue {
        let registrations = await rig.server.registrations()
        let entry = try #require(registrations.first { $0.0.id == id })
        return try #require(try await entry.1(rig.context(caller, folder: folder, tiers: tiers), .fromFoundation(args)).structuredContent)
    }
    @Test func bulkDatesAndTagsChangeSeveralTasksWithoutAssignment() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.io.root) }
        let a = try await r.create("A", crmParityValue(["labels": ["old"]]))
        let b = try await r.create("B", crmParityValue(["labels": ["keep"]]))
        let originalAssignees = try await [r.f.row(a)["assignee"], r.f.row(b)["assignee"]]
        let changed = try await call(r, "tasks.bulk", ["do": "due", "tasks": [a, b], "due_date": "2026-10-20"])
        #expect(changed["updated"].elements?.count == 2)
        #expect(try await r.f.row(a)["dueDate"].string == "2026-10-20")
        _ = try await call(r, "tasks.bulk", ["do": "tags", "tasks": [a, b], "labels": ["release"], "mode": "add"])
        #expect(try await r.f.row(a)["labels"].elements?.compactMap(\.string) == ["old", "release"])
        #expect(try await r.f.row(b)["labels"].elements?.compactMap(\.string) == ["keep", "release"])
        _ = try await call(r, "tasks.bulk", ["do": "tags", "tasks": [a, b], "labels": ["release"], "mode": "remove"])
        #expect(try await r.f.row(a)["labels"].elements?.compactMap(\.string) == ["old"])
        _ = try await call(r, "tasks.bulk", ["do": "tags", "tasks": [a, b], "labels": ["new"], "mode": "replace"])
        _ = try await call(r, "tasks.bulk", ["do": "tags", "tasks": [a, b], "mode": "clear"])
        _ = try await call(r, "tasks.bulk", ["do": "due", "tasks": [a, b], "due_date": NSNull()])
        #expect(try await r.f.row(a)["labels"].elements?.isEmpty == true)
        #expect(try await r.f.row(b)["dueDate"].isNullish == true)
        #expect(try await r.f.row(a)["assignee"] == originalAssignees[0])
        #expect(try await r.f.row(b)["assignee"] == originalAssignees[1])
        #expect(try await r.f.row(a)["sessionId"].isNullish == true)
    }
    @Test func everyIdIsCheckedBeforeAnyTaskChanges() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.io.root) }
        let a = try await r.create("Untouched")
        do { _ = try await call(r, "tasks.bulk", ["do": "due", "tasks": [a, "missing"], "due_date": "2026-10-20"]); Issue.record("Missing id allowed") } catch {}
        #expect(try await r.f.row(a)["dueDate"].isNullish)
        do { _ = try await call(r, "tasks.bulk", ["do": "due", "tasks": [a], "due_date": "2026-10-20"], folder: "/other"); Issue.record("Out of scope task allowed") } catch {}
        #expect(try await r.f.row(a)["dueDate"].isNullish)
    }
    @Test func readsAndChangesRespectToolGrants() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.io.root) }
        #expect(try await call(r, "tasks.views", ["do": "list"], tiers: [.read])["action"].string == "list")
        do { _ = try await call(r, "tasks.views", ["do": "save", "name": "test"], tiers: [.read]); Issue.record("Read-only saved view change") } catch {}
        do { _ = try await call(r, "tasks.views", ["do": "list"], caller: "denied"); Issue.record("No-grant view read") } catch {}
        do { _ = try await call(r, "tasks.bulk", ["do": "due", "tasks": ["x"], "due_date": NSNull()], tiers: [.read]); Issue.record("Read-only bulk change") } catch {}
    }
    @Test func invalidDatesAndDuplicateIdsDoNotChangeTasks() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.io.root) }
        let a = try await r.create("A")
        let invalids: [[String: Any]] = [
            ["do": "due", "tasks": [a], "due_date": "Tuesday"],
            ["do": "due", "tasks": [a, a], "due_date": "2026-10-20"],
            ["do": "assign", "tasks": [a], "assignee": "hoot"],
            ["do": "tags", "tasks": [a], "labels": ["x"], "mode": "bad"]
        ]
        for args in invalids {
            do { _ = try await call(r, "tasks.bulk", args); Issue.record("Invalid bulk change allowed") } catch {}
        }
        #expect(try await r.f.row(a)["dueDate"].isNullish)
    }
}
