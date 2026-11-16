import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendTaskMCPHandlersTests: XCTestCase, @unchecked Sendable {
    func testEveryRegisteredToolHasAHandlerAndShortDescription() async throws {
        let rig = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
        for (spec, _) in rig.registrations where spec.id.hasPrefix("tasks.") || spec.id == "hoot.island" || spec.id == "crm.task" {
            XCTAssertNotNil(BackendTaskMCPHandlers.operations[spec.id], spec.id)
            // 500 is our own tidy limit (9cf271ea3), not an AI app's: tasks.local_change carries the delete rule's words
            // (305839b7b, Delete rule L6: delete reaches every device at once, Bin 30 days, only the person puts back),
            // so it alone may run to 600. No AI app cuts or refuses a tool description of this length.
            XCTAssertLessThanOrEqual(spec.description.count, spec.id == "tasks.local_change" ? 600 : 500, spec.id)
            if let tiers = BackendTaskToolPolicy.overrides[spec.id] {
                let verbs = spec.inputSchema["properties"]["do"]["enum"].elements?.compactMap(\.string) ?? []
                XCTAssertEqual(Set(tiers.keys), Set(verbs), spec.id)
            }
        }
    }
    func testReadOnlyCallerCannotReachAnyMutatingVerb() async throws {
        let rig = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
        for (id, verbs) in BackendTaskToolPolicy.overrides {
            for (verb, tier) in verbs where tier != .read {
                do {
                    _ = try await rig.call(id, crmParityValue(["do": verb]), tiers: [.read])
                    XCTFail("Read-only caller reached \(id):\(verb)")
                } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "not-granted", id + ":" + verb) }
            }
        }
        XCTAssertEqual(BackendTaskToolPolicy.tier("tasks.crm_sync", arguments: .object([]), fallback: .read), .read)
        XCTAssertEqual(BackendTaskToolPolicy.tier("tasks.crm_sync", arguments: crmParityValue(["on": false]), fallback: .read), .act)
    }
    func testLocalHandlersPreserveEditsScopeAndProgressReplay() async throws {
        let rig = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
        let id = try await rig.create("Before", crmParityValue(["project": "/work/app", "assignee": "me"]))
        _ = try await rig.call("tasks.local_change", crmParityValue(["do": "update", "task": id, "title": "After"]))
        let row = try await rig.call("tasks.get", crmParityValue(["task": id]))
        XCTAssertEqual(row["title"], .string("After"))
        do {
            _ = try await rig.call("tasks.local", crmParityValue(["do": "get", "task": id]), folder: "/other")
            XCTFail("A caller read a task outside its project")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
        let input = crmParityValue(["task": id, "kind": "progress", "body": "Checked", "event_id": "p34-progress"])
        let first = try await rig.call("tasks.comment", input), replay = try await rig.call("tasks.comment", input)
        XCTAssertEqual(first["replayed"], .bool(false)); XCTAssertEqual(replay["replayed"], .bool(true))
    }
}
